###############################################################################
#
# SageMathCloud: A collaborative web-based interface to Sage, IPython, LaTeX and the Terminal.
#
#    Copyright (C) 2014, William Stein
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################


#################################################################
#
# stringsync -- a node.js module that is used by the hub to provide
# a differential synchronized string, which is persisted and synchronized
# across hubs via the database itself.
#
#  (c) William Stein, 2014
#
# Here's a diagram:
#
# [dc0 database state] .... [dc1 database state] <-----> [*hub*] <---> clients...
#        /|\
#         |-----[hub] <--> clients...
#
# This hub views it's in-memory current state of the string as the ultimate
# upstream for the string.  It views the database as one single downstream client,
# and some connected browser clients as other downstream clients.
# We query the database to see if any hashes have changed. with one single
# query for *all* strings, so polling scales.
#
#################################################################

###
Theoretical remarks.

The code here provides a solution to the general problem of an eventually
consistent synchronized string.  There are many standard choices and
tradeoffs and conventions in choosing such a solution.   For example,
if two writes in different locations occur at the same time (equal timestamps),
then it's basically random which diff is actually recorded.
... (should say more)
###


# The StringsDB class below models storing a distributed collection of strings, indexed by a uuid,
# in an eventually consistent database (Cassandra).
# It queries periodically, with exponetial backoff, for updates about strings that
# we're watching.  It assembles the patch stream in the database together to give
# a consistent view for each string, and also writes patches to propogate that view.
# Times below are in milliseconds.

# Polling parameters:
INIT_POLL_INTERVAL     = 3000
MAX_POLL_INTERVAL      = 20000   # TODO: for testing -- for deploy make longer!
POLL_DECAY_RATIO       = 1.4

# Maximum allowed syncstring size -- we keep this manageable since we have to be
# able to load the entire string within a few seconds from the database.
MAX_STRING_LENGTH      = 5000000

# We grab patches that are up to TIMESTAMP_OVERLAP old from db each time polling.
# We are assuming a write to the database propogates to
# all DC's after this much time.  Any change that failed to
# propogate after this long may be lost.  This way we still eventually see
# patches that were written to the database, but that we missed
# due to them not being propogates to all data centers.

TIMESTAMP_OVERLAP      = 60000
## TIMESTAMP_OVERLAP      = 15000

# If there are more than DB_PATCH_SQUASH_THRESH patches for a given string,
# we squash the old patch history into a single patch the first time
# we read the given synchronized string from the database.  This avoids
# having to apply hundreds of patches when opening a string, and saves
# space.   (Of course, having the complete history could also be
# interesting...)
DB_PATCH_SQUASH_THRESH = 20

async    = require('async')
{EventEmitter} = require('events')
winston = require('winston')

diffsync = require('diffsync')
misc     = require('misc')
message  = require('message')
cass     = require("cassandra")


{defaults, required} = misc

######################################################################################
# Building block:  This is a complete synchronized
# string session between one single browser client and the hub.
# With this, we can reduce all complicated multi-user sync
# stuff as happening within the hub (first move from a remote computer
# to local via sync, then do everything locally).
######################################################################################

class SyncStringBrowser extends diffsync.DiffSync
    constructor : (@syncstring, @session_id, @push_to_client) ->
        misc.call_lock(obj:@)
        @init(doc:@syncstring.head)
        @last_sync = @shadow

    _write_mesg: (event, obj, cb) =>
        if not obj?
            obj = {}
        obj.session_id = @session_id
        mesg = message['syncstring_' + event](obj)
        @push_to_client(mesg, cb)

    # After receiving and processing edits from the client, we then
    # call push_edits_to_browser to push our edits back to the
    # browser (in the response message.)
    push_edits_to_browser: (id, cb) =>
        f = (cb) =>
            @_push_edits_to_browser(id, cb)
            @syncstring.sync()
        @_call_with_lock(f, cb)

    _push_edits_to_browser: (id, cb) =>
        # if id is given, then we are responding to a sync request from the client.
        # if id not given, we are initiating the sync request.
        #dbg = (m) => winston.debug("push_edits_to_browser: #{m}")
        @push_edits (err) =>
            # this just computed @edit_stack and @last_version_received
            if err
                @push_to_client(message.error(error:err, id:id))
                cb?(err)
            else
                @last_sync = @shadow
                mesg =
                    id               : id
                    edit_stack       : @edit_stack
                    last_version_ack : @last_version_received
                # diffsync2 when sync initiated by hub; diffsync when initiated by browser client.
                @_write_mesg "diffsync#{if id? then '' else '2'}", mesg, (err, resp) =>
                    if err
                        cb?(err)
                    else
                        if resp?
                            @recv_edits(resp.edit_stack, resp.last_version_ack, cb)
                            @last_sync = @shadow
                        else
                            cb?()

    sync: (cb) =>
        @push_edits_to_browser(undefined, cb)

# A string that is synchronized amongst all connected clients.
# IMPORTANT: anything in the string after @max_size
# will be automatically truncated -- i.e., if any operation results
# in the string getting longer than that, it is truncated at the end.  It is
# the responsibility of the client code to properly deal with this, e.g.,
# by putting a sentinel character at the end of the string and checking for
# it to see if the string was truncated as a result of a sync.

# x={};require('bup_server').global_client(cb:(e,c)->x.c=c; x.s = require('syncstring'); x.s.init_syncstring_db(x.c.database); x.ss=x.s.get_syncstring_db(); x.s.get_syncstring(string_id:'4bd8cb98-506c-45a5-8042-5c6bd8fddff0',max_length:50,cb:(e,t)->x.t=t))
class SynchronizedString
    constructor: (@string_id, @max_length) ->
        misc.call_lock(obj:@)
        @clients = {}
        @head = ''
        if not @max_length?
            @max_length = MAX_STRING_LENGTH
        else
            # no matter what, we never allow syncstrings to exceed the MAX_STRING_SIZE
            @max_length = Math.min(@max_length, MAX_STRING_LENGTH)

    new_browser_client: (opts) =>
        opts = defaults opts,
            session_id     : required
            push_to_client : required
            cb             : required
        client = new SyncStringBrowser(@, opts.session_id, opts.push_to_client)
        client.id = opts.session_id
        @clients[opts.session_id] = client
        opts.cb(undefined, client)

    new_in_memory_client: (opts) =>
        opts = defaults opts,
            session_id    : required
            cb            : required
        # Used so that the hub itself (the process where this code is running)
        # can modify this SynchronizedString, rather than just remote clients.
        client = new diffsync.DiffSync(doc:@head)
        client.id = opts.session_id
        client.sync = (cb) =>
            if client.live.length > @max_length
                client.live = client.live.slice(0,@max_length)
            client.shadow    = client.live
            client.last_sync = client.live
            client.emit('sync')
            @sync()
            cb?()
        @clients[opts.session_id] = client
        opts.cb(undefined, client)

    new_database_client: (opts) =>
        opts = defaults opts,
            session_id    : required
            squash_thresh : DB_PATCH_SQUASH_THRESH
            cb            : required
        # Used for synchronizing/persisting the string using the database, so
        # it gets sync'd across all hubs (across data centers).
        syncstring_db.get_string
            string_id     : @string_id
            squash_thresh : opts.squash_thresh
            cb            : (err, client) =>
                if err
                    opts.cb(err)
                else
                    if client.live.length > @max_length
                        client.live = client.live.slice(0,@max_length)
                    @clients[opts.session_id] = client
                    opts.cb(undefined, client)

    sync: (cb) =>
        @_call_with_lock(@_sync, cb)

    _sync: (cb, retry) =>
        last = @head
        #winston.debug("sync: last='#{last}'")
        all = {}
        all[last] = true
        for _, client of @clients
            all[client.live] = true
        if misc.len(all) <= 1
            # nothing to do
            #winston.debug("sync: nothing to do")
            cb?()
            return

        v = []
        for _, client of @clients
            t0 = misc.mswalltime()
            #winston.debug("local_client_sync: start...")
            v.push(client)
            patch = diffsync.dmp.patch_make(last, client.live)
            #winston.debug("local_client_sync: computing patch in #{misc.mswalltime(t0)}ms"); t0 = misc.mswalltime()
            @head = diffsync.dmp.patch_apply(patch, @head)[0]
            #winston.debug("local_client_sync: applied patch in #{misc.mswalltime(t0)}ms"); t0 = misc.mswalltime()
            #winston.debug("sync: new head='#{@head}' from patch=#{misc.to_json(patch)}")

        for _, client of @clients
            client.live = @head

        # Sync any that changed (all at once, in parallel).
        successful_live = {}
        successful_live[@head] = true
        f = (client, cb) =>
            if client.last_sync != @head
                #winston.debug("syncing '#{client.last_sync}' <--> '#{@head}'")
                t = misc.mswalltime()
                client.sync (err) =>
                    #winston.debug("sync time=#{misc.mswalltime(t)}")
                    if err == 'disconnected'
                        delete @clients[client.id]
                    if err
                        winston.debug("sync err = #{err}")
                    else
                        successful_live[client.live] = true
                    cb()
            else
                cb()
        async.map v, f, () =>
            if not retry and misc.len(successful_live) > 0
                # if not stable (with ones with no err), do again; but not more than once.
                #winston.debug("syncing again")
                @_sync(cb, true)
            else
                #winston.debug("not syncing again since successful_live='#{misc.to_json(successful_live)}'")
                cb?()

sync_strings = {}

exports.get_syncstring = get_syncstring = (opts) ->
    opts = defaults opts,
        string_id  : required
        max_length : MAX_STRING_LENGTH   # max length of string; anything more gets silently truncated!
        cb         : required
    if opts.max_length > MAX_STRING_LENGTH
        opts.cb("max_length of string may be at most #{MAX_STRING_LENGTH}")
        return
    S = sync_strings[opts.string_id]
    if S?
        opts.cb(undefined, S); return

    S = new SynchronizedString(opts.string_id, opts.max_length)
    async.series([
        (cb) =>
            S.new_database_client
                session_id : misc.uuid()
                cb : (err, client) ->
                    if err
                        cb(err)
                    else
                        S.db_client = client
                        S.head = client.live
                        client.on 'change', S.sync  # whenever database changes, sync everything
                        cb()
        (cb) =>
            S.new_in_memory_client
                session_id : misc.uuid()
                cb         : (err, client) ->
                    if err
                        cb(err)
                    else
                        S.in_memory_client = client
                        cb()
    ], (err) =>
        if err
            # TODO: undo any other harm
            opts.cb(err)
        else
            sync_strings[opts.string_id] = S
            opts.cb(undefined, S)
    )

exports.syncstring = (opts) ->
    opts = defaults opts,
        string_id      : required
        session_id     : required
        push_to_client : required    # function that allows for sending a JSON message to remote client
        max_length     : undefined
        cb             : required
    get_syncstring
        string_id  : opts.string_id
        max_length : opts.max_length
        cb         : (err, S) =>
            if err
                opts.cb(err)
            else
                S.new_browser_client
                    session_id     : opts.session_id
                    push_to_client : opts.push_to_client
                    cb             : (err, client) ->
                        if err
                            opts.cb(err)
                        else
                            opts.cb(undefined, client)

# The hub has to call this on startup in order for syncstring to work.
syncstring_db = undefined
exports.init_syncstring_db = (database, cb) ->
    if not database?  # for debugging/testing on command line
        database = new cass.Salvus
            hosts       : ['localhost']
            keyspace    : 'salvus'
            username    : 'hub'
            cb          : (err) ->
                if not err
                    syncstring_db = new StringsDB(database)
                cb?(err)
    else
        syncstring_db = new StringsDB(database)
        cb?()


exports.get_syncstring_db = () ->
    return syncstring_db


# oldest first -- unlike in page/activity.coffee
timestamp_cmp = (a,b) ->
    if a.timestamp < b.timestamp
        return -1
    else if a.timestamp > b.timestamp
        return +1
    return 0



# emits a 'change' event whenever live is changed as a result of syncing with the database
class StringsDBString extends EventEmitter
    constructor: (@strings_db, @string_id) ->
        @applied_patches = {}
        @last_sync = ''
        @live = ''
        @timestamp = 0
        @patch_counter = 0

    sync: (cb) =>
        @strings_db.sync([@string_id], cb)

class StringsDB
    constructor : (@db) ->
        if not @db?
            # TODO: for testing only
            @db = new cass.Salvus
                hosts       : ['localhost']
                keyspace    : 'salvus'
                consistency : 1
                cb          : (err) =>
                    if err
                        console.log("FAILED to connect to db")
                    else
                        console.log("connected to db")
        misc.call_lock(obj:@)
        @strings = {}    # synchronized strings we're watching
        @poll_for_updates() # start polling

    # DO NOT CHANGE THESE TWO FUNCTIONS, ever!  It'll break everything in the db
    patch_to_string: (patch) => JSON.stringify(diffsync.compress_patch(patch))

    string_to_patch: (patch) => diffsync.decompress_patch_compat(JSON.parse(patch))

    dbg: (f, m) =>
        winston.debug("StringsDB.#{f}: #{m}")
        #console.log("StringsDB.#{f}: #{m}")

    get_string: (opts) =>
        opts = defaults opts,
            string_id     : required
            squash_thresh : DB_PATCH_SQUASH_THRESH
            cb            : required
        s = @strings[opts.string_id]
        if s?
            opts.cb(undefined, s)
        else
            # If this gets called multiple times, then do only once and call all callbacks
            if not @_get_string_queue?
                @_get_string_queue = {}
            if @_get_string_queue[opts.string_id]?
                @_get_string_queue[opts.string_id].push(opts.cb)
                return
            f = (args...) =>
                for cb in @_get_string_queue[opts.string_id]
                    cb(args...)

            @_get_string_queue[opts.string_id] = [opts.cb]

            @_read_updates_from_db [opts.string_id], 0, opts.squash_thresh, (err) =>
                if err
                    f(err)
                else
                    s = @strings[opts.string_id]
                    if not s?
                        s = @strings[opts.string_id] = new StringsDBString(@, opts.string_id)
                    s.live = s.last_sync # start initialized to what is in db
                    f(undefined, s)

    # This is mostly a throw-away function for maintenance in the early low-usage days.
    # This queries the syncstring_acls table for all syncstring id’s, one by one
    # goes through and loads them and combines all the patches into a single patch.
    # As it goes, it also record the total length of the resulting syncstring.
    # x={};require('bup_server').global_client(cb:(e,c)->x.c=c; x.s = require('syncstring'); x.s.init_syncstring_db(x.c.database); x.ss=x.s.get_syncstring_db();  x.ss.compact(start:0,stop:100,cb:(e)->console.log("DONE",e)))
    # NOTE: this only compacts strings with id in syncstring_acls; querying the
    # string_id column of syncstrings is a lot slower, though could be implemented, of course.
    compact: (opts)  =>
        opts = defaults opts,
            start      : 0
            stop       : 100
            string_ids : undefined
            cb         : undefined

        v = undefined
        async.series([
            (cb) =>
                ## v = ['4bd8cb98-506c-45a5-8042-5c6bd8fddff0']; cb(); return
                winston.info("compact: querying for all string ids...")
                if opts.string_ids?
                    v = opts.string_ids
                    cb()
                    return
                @db.select
                    table   : 'syncstring_acls'
                    columns : ['string_id']
                    cb      : (err, results) =>
                        if err
                            cb(err)
                        else
                            v = (x[0] for x in results)
                            v.sort()
                            if opts.stop?
                                v = v.slice(opts.start, opts.stop)
                            else if opts.start
                                v = v.slice(opts.start)
                            winston.info("compact: there are #{v.length} syncstrings")
                            cb()
            (cb) =>
                i = opts.start
                f = (string_id, c) =>
                    winston.info("compact: #{i}/#{v.length-1+opts.start} - loading #{string_id}...")
                    i += 1
                    @squash_old_patches
                        string_id     : string_id
                        cb            : c
                async.mapLimit(v, 1, f, (err) => cb(err))
            ], (err) =>
                opts.cb?(err)
        )


    poll_for_updates: (interval=INIT_POLL_INTERVAL) =>
        retry = (interval) =>
            next_interval = Math.max(INIT_POLL_INTERVAL, Math.min(MAX_POLL_INTERVAL, POLL_DECAY_RATIO*interval))
            #@dbg("poll_for_updates", "waiting #{next_interval/1000}s...")
            setTimeout((()=>@poll_for_updates(next_interval)), interval)

        if misc.len(@strings) == 0
            # not watching for anything
            retry(interval); return

        @read_updates_from_db
            string_ids : misc.keys(@strings)
            cb         : (err, new_updates) =>
                if err
                    retry(interval)
                else
                    if new_updates
                        # something new -- poll again soon
                        retry(0)
                    else
                        # nothing new -- try again after further exponential decay
                        retry(interval)

    sync: (string_ids, cb) =>
        @_call_with_lock(((c)=>@_write_updates_to_db(string_ids,c)), cb)

    _write_updates_to_db: (string_ids, cb) =>
        if not @db?
            cb("database not initialized"); return
        dbg = (m) => @dbg("_write_updates_to_db", m)
        dbg()
        f = (string_id, cb) =>
            #dbg(string_id)
            string = @strings[string_id]
            #dbg("string.last_sync='#{string.last_sync}'")
            #dbg("string.live='#{string.live}'")
            if string.last_sync == string.live
                #dbg("nothing to do for #{string_id}")
                cb() # nothing to do
            else
                t0 = misc.mswalltime()
                #dbg("starting patch make from length #{string.last_sync.length} to #{string.live.length}...")
                patch = diffsync.dmp.patch_make(string.last_sync, string.live)
                #dbg("made patch for #{string_id} in #{misc.mswalltime(t0)}ms"); t0 = misc.mswalltime()
                #dbg("patch for #{string_id} = #{misc.to_json(patch)}")
                timestamp = cass.now() - 0
                patch_as_string = @patch_to_string(patch)
                #dbg("converted patch to string in #{misc.mswalltime(t0)}ms"); t0 = misc.mswalltime()
                @db.update
                    table : 'syncstrings'
                    set   : {patch:patch_as_string}
                    where : {string_id:string_id, timestamp:timestamp}
                    cb    : (err) =>
                        #dbg("wrote patch to database in #{misc.mswalltime(t0)}ms"); t0 = misc.mswalltime()
                        if err
                            cb(err)
                        else
                            #dbg("success for #{string_id}")
                            string.last_sync = string.live
                            string.applied_patches[timestamp] = {patch:patch, timestamp:timestamp}
                            string.timestamp = timestamp
                            string.patch_counter += 1
                            if string.patch_counter >= DB_PATCH_SQUASH_THRESH
                                @squash_old_patches
                                    string_id : string_id
                                    cb        : cb
                            else
                                cb()
        async.map(string_ids, f, (err) => cb(err))

    read_updates_from_db: (opts) =>
        opts = defaults opts,
            string_ids    : required   # list of strings
            age           : TIMESTAMP_OVERLAP
            squash_thresh : DB_PATCH_SQUASH_THRESH
            cb            : required
        @_call_with_lock(((cb)=>@_read_updates_from_db(opts.string_ids, opts.age,  opts.squash_thresh, cb)), opts.cb)

    _read_updates_from_db: (string_ids, age, squash_thresh, cb) =>
        if not @db?
            cb("database not initialized"); return
        if string_ids.length == 1
            @dbg("_read_updates_from_db", "querying updates for #{string_ids[0]}")
        else
            @dbg("_read_updates_from_db", "querying updates for #{string_ids.length} strings")
        where = {string_id:{'in':string_ids}}
        if age
            where.timestamp = {'>=' : cass.now() - age}
        @db.select
            table     : 'syncstrings'
            columns   : ['string_id','timestamp','patch','is_first']
            objectify : true
            where     : where
            cb        : (err, updates) =>
                if err
                    cb(err)
                else
                    @_process_updates updates, squash_thresh, (err, new_updates) =>
                        # ignore err, since it would be in writing back
                        cb(undefined, new_updates)

    _process_updates: (updates, squash_thresh, cb) =>
        #
        # updates is a list of {string_id:?,timestamp:?,patch:?,is_first:?} objects, where
        #
        #   string_id = string uuid
        #   timestamp = Date object
        #   patch     = string representation of a patch (since we don't want to de-JSON if not needed)
        #   is_first  = boolean; if true, start with this patch; used only to avoid race conditions when trimming history.

        if updates.length > 0
            @dbg("_process_updates", "process #{updates.length} updates")
            #@dbg("_process_updates", "#{misc.to_json(updates)}")
        new_patches = {}
        t0 = misc.mswalltime()
        for update in updates
            update.timestamp = update.timestamp - 0  # better to key map based on string of timestamp as number
            string = @strings[update.string_id]
            if not string?
                string = @strings[update.string_id] = new StringsDBString(@, update.string_id)
            if not string.applied_patches[update.timestamp]?
                # a new patch
                update.patch = @string_to_patch(update.patch)
                if not new_patches[update.string_id]?
                    new_patches[update.string_id] = [update]
                else
                    new_patches[update.string_id].push(update)

        if misc.len(new_patches) == 0
            #@dbg("_process_updates", "no new patches, so nothing further to do")
            cb(undefined, false)
            return

        #if updates.length > 0
        #    @dbg("_process_updates",misc.to_json(new_patches))
        @dbg("_process_updates", "#{misc.len(new_patches)} new patches")

        # There are new patches
        write_updates = []
        for string_id, patches of new_patches
            string = @strings[string_id]
            last_sync_before = string.last_sync

            patches.sort(timestamp_cmp)

            # If any patch has the is_first property set, ignore
            # all the patches before it.  Note that since we only trim older
            # patches, if this happens we are initializing the string from
            # scratch.   This trimming would only happen in extremely rare
            # conditions where the squashed patch has been written to the db,
            # but the older patches haven't yet been removed (it's only necessary
            # due to lack of transactions).
            i = patches.length - 1
            while i > 0
                if patches[i].is_first
                    if i > 0
                        winston.debug("some older patches are no longer needed -- deleting from DB")
                    for p in patches.slice(0,i)
                        @db.delete
                            table : 'syncstrings'
                            where :
                                string_id : string_id
                                timestamp : p.timestamp
                    patches = patches.slice(i)
                    break
                i -= 1

            if patches[0].timestamp < string.timestamp
                #@dbg("_process_updates", "timestamps not all bigger than last patch time (=#{misc.to_json(string.timestamp)}): patches=#{misc.to_json(patches)}")
                # If timestamps not all bigger than last patch time, we make list of all patches
                # apply all in order, starting from scratch.  (TODO: optimize)
                for _, patch of string.applied_patches
                    patches.push(patch)
                patches.sort(timestamp_cmp)
                # reset string
                string.last_sync = ''
                string.timestamp = 0
                string.applied_patches = {}

            # Determine whether or not to squash the patches into a single patch.
            if patches.length > squash_thresh
                squash = true
                squash_time = new Date() - 1.2*TIMESTAMP_OVERLAP
            else
                squash = false

            #@dbg("_process_updates", "squash=#{squash}; squash_time=#{squash_time}")

            # Apply unapplied patches in order.
            i = 0
            t1 = misc.mswalltime()
            for p in patches
                #@dbg("_process_updates","applying unapplied patch #{misc.to_json(p.patch)}")
                try
                    string.last_sync = diffsync.dmp.patch_apply(p.patch, string.last_sync)[0]
                catch e
                    winston.debug("syncstring database error applying a patch -- failed due to corruption (?) -- #{misc.to_json(p.patch)} -- err=#{e}")
                string.applied_patches[p.timestamp] = p
                if squash and p.timestamp <= squash_time and (i == patches.length-1 or patches[i+1].timestamp > squash_time)
                    @_squash_patches
                        to_delete : (x.timestamp for x in patches.slice(0, i))
                        string_id : string_id
                        value     : string.last_sync
                        timestamp : p.timestamp
                i += 1


            # string's timestamp = Newest applied patch
            string.timestamp = patches[patches.length - 1].timestamp

            # apply effective changes from db to live.
            if last_sync_before != string.last_sync
                patch = diffsync.dmp.patch_make(last_sync_before, string.last_sync)
                string.live = diffsync.dmp.patch_apply(patch, string.live)[0]
                string.emit('change')

            t1 = misc.mswalltime(t1)
            # If live != last_sync, write our changes back to database
            if string.live != string.last_sync
                write_updates.push(string_id)

        if updates.length > 0
            @dbg("_process_updates", "took #{misc.mswalltime(t0)}ms to process #{updates.length} updates, with #{t1}ms spent on patching")
        if write_updates.length > 0
            #@dbg("_process_updates","writing our own updates back")
            # safe to call skipping lock, since we have the lock
            @_write_updates_to_db write_updates, (err) =>
                cb(err, true)
        else
            #@dbg("_process_updates","no further updates from us (stable)")
            cb(undefined, true)


    _squash_patches: (opts) =>
        opts = defaults opts,
            string_id : required
            value     : required
            timestamp : required
            to_delete : required
            cb        : undefined
        @dbg("_squash_patches", "string_id=#{opts.string_id}")
        async.series([
            (cb) =>
                # write big new patch
                patch = diffsync.dmp.patch_make('', opts.value)
                @db.update
                    table : 'syncstrings'
                    set   :
                        patch    : @patch_to_string(patch)
                        is_first : true
                    where :
                        string_id : opts.string_id
                        timestamp : opts.timestamp
                    cb    : cb
            (cb) =>
                # delete now-redundant old patches (in parallel)
                f = (timestamp, cb) =>
                    @db.delete
                        table : 'syncstrings'
                        where :
                            string_id : opts.string_id
                            timestamp : timestamp
                        cb    : cb
                async.map(opts.to_delete, f, (err) => cb(err))
        ], (err) =>
            if not err
                string = @strings[opts.string_id]
                if string?
                    string.patch_counter = 1
            opts.cb?(err)
        )

    # Squash all patches in the database older than squash_time
    # into a single patch.  If succcessful, also resets the
    # patch_counter for the synchronized string if @strings[string_id]
    # is defined.
    squash_old_patches: (opts) =>
        opts = defaults opts,
            string_id : required
            cb        : undefined
        dbg = (m) => @dbg("squash_old_patches(string_id=#{opts.string_id})", m)
        dbg()

        patches     = undefined
        to_delete   = undefined
        timestamp   = undefined
        value       = undefined
        async.series([
            (cb) =>
                # Get all the patches in the database for this string that
                # are at least 1.2*TIMESTAMP_OVERLAP old, so by *hypothesis*
                # they have all already been seen by all active clients.
                @db.select
                    table     : 'syncstrings'
                    where     :
                        string_id : opts.string_id
                        timestamp : {'<=' : new Date() - 1.2*TIMESTAMP_OVERLAP}
                    columns   : ['timestamp', 'patch', 'is_first']
                    objectify : true
                    cb        : (err, r) =>
                        if err
                            cb(err)
                        else
                            # Sort the patches we just read from oldest to newest.
                            patches = r
                            patches.sort(timestamp_cmp)
                            # If we successfully squash them, then these are the timestamps
                            # of patches that we will delete:
                            to_delete = (x.timestamp for x in patches.slice(0,patches.length-1))
                            # If one patch is marked as is_first, delete everything before it.
                            for i in [0...patches.length]
                                j = patches.length - i - 1  # go from right to left!
                                if patches[j].is_first
                                    patches = patches.slice(j)
                                    break
                            # Compute value of concatenation of all patches we're using, which
                            # together defines the state of the string at the newest patch time.
                            # This operation could be expensive if there were a large number
                            # of patches, but there shouldn't be since we squash regularly.
                            t0  = misc.mswalltime()
                            value = ''
                            for p in patches
                                try
                                    value = diffsync.dmp.patch_apply(@string_to_patch(p.patch), value)[0]
                                catch e
                                    # This should never happen -- it would only happen if a patch were
                                    # somehow corrupted, which should be impossible.  But it's better
                                    # to catch and move on then destroy the syncstring entirely.
                                    dbg("error applying patch -- #{misc.to_json(p.patch)} -- err=#{e}")
                            dbg("patch_apply took a total of #{misc.mswalltime(t0)}ms")
                            cb()
            (cb) =>
                if patches.length == 0
                    cb(); return
                # Now do the actual squash operation and delete old patches from the database.
                @_squash_patches
                    string_id : opts.string_id
                    value     : value
                    timestamp : patches[patches.length-1].timestamp
                    to_delete : to_delete
                    cb        : cb
        ], (err) =>
            opts.cb?(err)
            string = @strings[opts.string_id]
            if string?
                @dbg("reset patch_counter")
                string.patch_counter = 0
        )


#---------------------------------------------------------------------
# Synchronized document-oriented database, based on SynchronizedString
# This is the version run by hubs.
# There is a corresponding implementation run by clients.
#---------------------------------------------------------------------

###
x={};require('bup_server').global_client(cb:(e,c)->x.c=c; x.s = require('syncstring'); x.s.init_syncstring_db(x.c.database); x.ss=x.s.syncdb(string_id:'4bd8cb98-506c-45a5-8042-5c6bd8fddff1', cb:(e,t)->x.t=t))
###
_syncdb_cache = {}
exports.syncdb = (opts) ->
    opts = defaults opts,
        string_id      : required
        max_length     : MAX_STRING_LENGTH
        cb             : required
    d = _syncdb_cache[opts.string_id]
    if d?
        opts.cb(undefined, d)
        return
    get_syncstring
        string_id  : opts.string_id
        max_length : opts.max_length
        cb         : (err, S) =>
            if err
                opts.cb(err)
            else
                doc = new diffsync.SynchronizedDB_DiffSyncWrapper(S.in_memory_client)
                S.db_client.on 'changed', () =>
                    doc.emit("sync")
                d = _syncdb_cache[opts.string_id] = new diffsync.SynchronizedDB(doc)
                d.string_id = opts.string_id
                opts.cb(undefined, d)


