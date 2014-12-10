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


#########################################################################
#
# Interface to the Cassandra Database.
#
# *ALL* DB queries (using CQL, etc.) should be in this file, with
# *Cassandra/CQL agnostic wrapper functions defined here.   E.g.,
# to find out if an email address is available, define a function
# here that does the CQL query.
# Well, calling "select" is ok, but don't ever directly write
# CQL statements.
#
# fs=require('fs'); a = new (require("cassandra").Salvus)(keyspace:'salvus', hosts:['10.1.1.2:9160'], username:'salvus', password:fs.readFileSync('data/secrets/cassandra/salvus').toString().trim(), cb:console.log)
# fs=require('fs'); a = new (require("cassandra").Salvus)(keyspace:'salvus', hosts:['10.1.1.2:9160'], username:'hub', password:fs.readFileSync('data/secrets/cassandra/hub').toString().trim(), cb:console.log)
#
# fs=require('fs'); a = new (require("cassandra").Salvus)(keyspace:'salvus', hosts:['localhost:8403'], username:'salvus', password:fs.readFileSync('data/secrets/cassandra/salvus').toString().trim(), cb:console.log)
#
# a = new (require("cassandra").Salvus)(keyspace:'salvus', hosts:['localhost'], cb:console.log)
#
#########################################################################

# This is used for project servers.  [[um, -- except it isn't actually used at all anywhere! (oct 11, 2013)]]
MAX_SCORE = 3
MIN_SCORE = -3   # if hit, server is considered busted.

# recent times, used for recently_modified_projects
exports.RECENT_TIMES = RECENT_TIMES =
    short : 5*60
    day   : 60*60*24
    week  : 60*60*24*7
    month : 60*60*24*7*30

RECENT_TIMES_ARRAY = ({desc:desc,ttl:ttl} for desc,ttl of RECENT_TIMES)

misc    = require('misc')
misc_node = require('misc_node')

PROJECT_GROUPS = misc.PROJECT_GROUPS

{to_json, from_json, defaults} = misc
required = defaults.required

fs      = require('fs')
assert  = require('assert')
async   = require('async')
winston = require('winston')                    # https://github.com/flatiron/winston

cql     = require("cassandra-driver")
Client  = cql.Client  # https://github.com/datastax/nodejs-driver
uuid    = require('node-uuid')
{EventEmitter} = require('events')

moment  = require('moment')

_ = require('underscore')

CONSISTENCIES = (cql.types.consistencies[k] for k in ['any', 'one', 'two', 'three', 'quorum', 'localQuorum', 'eachQuorum', 'all'])

higher_consistency = (consistency) ->
    if not consistency?
        return cql.types.consistencies.any
    else if consistency == 1
        consistency = 'one'
    else if consistency == 2
        consistency = 'two'
    else if consistency == 3
        consistency = 'three'
    i = CONSISTENCIES.indexOf(consistency)
    if i == -1
        # unknown -- ?
        return cql.types.consistencies.localQuorum
    else
        return CONSISTENCIES[Math.min(CONSISTENCIES.length-1,i+1)]


# the time right now, in iso format ready to insert into the database:
now = exports.now = () -> new Date()

# the time ms milliseconds ago, in iso format ready to insert into the database:
exports.milliseconds_ago = (ms) -> new Date(new Date() - ms)
exports.seconds_ago      = (s)  -> exports.milliseconds_ago(1000*s)
exports.minutes_ago      = (m)  -> exports.seconds_ago(60*m)
exports.hours_ago        = (h)  -> exports.minutes_ago(60*h)
exports.days_ago         = (d)  -> exports.hours_ago(24*d)

# inet type: see https://github.com/jorgebay/node-cassandra-cql/issues/61

exports.inet_to_str = (r) -> [r[0], r[1], r[2], r[3]].join('.')


#########################################################################

PROJECT_COLUMNS = exports.PROJECT_COLUMNS = ['project_id', 'account_id', 'title', 'last_edited', 'description', 'public', 'bup_location', 'size', 'deleted', 'hide_from_accounts'].concat(PROJECT_GROUPS)

exports.PUBLIC_PROJECT_COLUMNS = ['project_id', 'title', 'last_edited', 'description', 'public', 'bup_location', 'size', 'deleted']

exports.create_schema = (conn, cb) ->
    t = misc.walltime()
    blocks = require('fs').readFileSync('db_schema.cql', 'utf8').split('CREATE')
    f = (s, cb) ->
        console.log(s)
        if s.length > 0
            conn.cql("CREATE "+s, [], ((e,r)->console.log(e) if e; cb(null,0)))
        else
            cb(null, 0)
    async.mapSeries blocks, f, (err, results) ->
        winston.info("created schema in #{misc.walltime()-t} seconds.")
        winston.info(err)
        cb(err)

class UUIDStore
    set: (opts) ->
        opts = defaults opts,
            uuid        : undefined
            value       : undefined
            ttl         : 0
            consistency : undefined
            cb          : undefined
        if not opts.uuid?
            opts.uuid = uuid.v4()
        else
            if not misc.is_valid_uuid_string(opts.uuid)
                throw "invalid uuid #{opts.uuid}"
        @cassandra.update
            table       : @_table
            where       : {name:@opts.name, uuid:opts.uuid}
            set         : {value:@_to_db(opts.value)}
            ttl         : opts.ttl
            consistency : opts.consistency
            cb          : opts.cb
        return opts.uuid

    # returns 0 if there is no ttl set; undefined if no object in table
    get_ttl: (opts) =>
        opts = defaults opts,
            uuid : required
            cb   : required

        @cassandra.select
            table  : @_table
            where  : {name:@opts.name, uuid:opts.uuid}
            columns : ['ttl(value)']
            objectify : false
            cb     : (err, result) =>
                if err
                    opts.cb(err)
                else
                    ttl = result[0]?[0]
                    if ttl == null
                        ttl = 0
                    opts.cb(err, ttl)

    # change the ttl of an existing entry -- requires re-insertion, which wastes network bandwidth...
    _set_ttl: (opts) =>
        opts = defaults opts,
            uuid : required
            ttl  : 0         # no ttl
            cb   : undefined
        @get
            uuid : opts.uuid
            cb : (err, value) =>
                if value?
                    @set
                        uuid  : opts.uuid
                        value : value      # note -- the implicit conversion between buf and string is *necessary*, sadly.
                        ttl   : opts.ttl
                        cb    : opts.cb
                else
                    opts.cb?(err)

    # Set ttls for all given uuids at once; expensive if needs to change ttl, but cheap otherwise.
    set_ttls: (opts) =>
        opts = defaults opts,
            uuids : required    # array of strings/uuids
            ttl   : 0
            cb    : undefined
        if opts.uuids.length == 0
            opts.cb?()
            return
        @cassandra.select
            table   : @_table
            columns : ['ttl(value)', 'uuid']
            where   : {name:@opts.name, uuid:{'in':opts.uuids}}
            objectify : true
            cb      : (err, results) =>
                if err
                    opts.cb?(err)
                else
                    f = (r, cb) =>
                        if r['ttl(value)'] != opts.ttl
                            @_set_ttl
                                uuid : r.uuid
                                ttl  : opts.ttl
                                cb   : cb
                        else
                            cb()
                    async.map(results, f, opts.cb)

    # Set ttl only for one ttl; expensive if needs to change ttl, but cheap otherwise.
    set_ttl: (opts) =>
        opts = defaults opts,
            uuid : required
            ttl  : 0         # no ttl
            cb   : undefined
        @set_ttls
            uuids : [opts.uuid]
            ttl   : opts.ttl
            cb    : opts.cb


    get: (opts) ->
        opts = defaults opts,
            uuid        : required
            consistency : undefined
            cb          : required
        if not misc.is_valid_uuid_string(opts.uuid)
            opts.cb("invalid uuid #{opts.uuid}")
        @cassandra.select
            table       : @_table
            columns     : ['value']
            where       : {name:@opts.name, uuid:opts.uuid}
            consistency : opts.consistency
            cb          : (err, results) =>
                if err
                    opts.cb(err)
                else
                    if results.length == 0
                        opts.cb(false, undefined)
                    else
                        r = results[0][0]
                        if r == null
                            opts.cb(false, undefined)
                        else
                            opts.cb(false, @_from_db(r))

    delete: (opts) ->
        opts = defaults opts,
            uuid : required
            cb   : undefined
        if not misc.is_valid_uuid_string(opts.uuid)
            opts.cb?("invalid uuid #{opts.uuid}")
        @cassandra.delete
            table : @_table
            where : {name:@opts.name, uuid:opts.uuid}
            cb    : opts.cb

    delete_all: (opts={}) ->
        opts = defaults(opts,  cb:undefined)
        @cassandra.delete
            table : @_table
            where : {name:@opts.name}
            cb    : opts.cb

    length: (opts={}) ->
        opts = defaults(opts,  cb:undefined)
        @cassandra.count
            table : @_table
            where : {name:@opts.name}
            cb    : opts.cb

    all: (opts={}) ->
        opts = defaults(opts,  cb:required)
        @cassandra.select
            table   : @_table
            columns : ['uuid', 'value']
            where   : {name:@opts.name},
            cb      : (err, results) ->
                obj = {}
                for r in results
                    obj[r[0]] = @_from_db(r[1])
                opts.cb(err, obj)

class UUIDValueStore extends UUIDStore
    # c = new (require("cassandra").Salvus)(keyspace:'test'); s = c.uuid_value_store(name:'sage')
    # uid = s.set(value:{host:'localhost', port:5000}, ttl:30, cb:console.log)
    # uid = u.set(value:{host:'localhost', port:5000})
    # u.get(uuid:uid, cb:console.log)
    constructor: (@cassandra, opts={}) ->
        @opts = defaults(opts,  name:required)
        @_table = 'uuid_value'
        @_to_db = to_json
        @_from_db = from_json

class UUIDBlobStore extends UUIDStore
    # c = new (require("cassandra").Salvus)(keyspace:'salvus'); s = c.uuid_blob_store(name:'test')
    # b = new Buffer("hi\u0000there"); uuid = s.set(value:b, ttl:300, cb:console.log)
    # s.get(uuid: uuid, cb:(e,r) -> console.log(r))
    constructor: (@cassandra, opts={}) ->
        @opts     = defaults(opts, name:required)
        @_table   = 'uuid_blob'
        @_to_db   = (x) -> x
        @_from_db = (x) -> new Buffer(x, 'hex')

class KeyValueStore
    #   c = new (require("cassandra").Salvus)(); d = c.key_value_store('test')
    #   d.set(key:[1,2], value:[465, {abc:123, xyz:[1,2]}], ttl:5)
    #   d.get(key:[1,2], console.log)   # but call it again in > 5 seconds and get nothing...
    constructor: (@cassandra, opts={}) ->
        @opts = defaults(opts,  name:required)

    set: (opts={}) =>
        opts = defaults opts,
            key         : undefined
            value       : undefined
            ttl         : 0
            consistency : undefined
            cb          : undefined

         @cassandra.update
            table       : 'key_value'
            where       : {name:@opts.name, key:to_json(opts.key)}
            set         : {value:to_json(opts.value)}
            ttl         : opts.ttl
            consistency : opts.consistency
            cb          : opts.cb

    get: (opts={}) =>
        opts = defaults opts,
            key         : undefined
            timestamp   : false      # if specified, result is {value:the_value, timestamp:the_timestamp} instead of just value.
            consistency : undefined
            cb          : undefined  # cb(error, value)
        if opts.timestamp
            @cassandra.select
                table       : 'key_value'
                columns     : ['value']
                timestamp   : ['value']
                where       : {name:@opts.name, key:to_json(opts.key)}
                consistency : opts.consistency
                cb          : (error, results) =>
                    if error
                        opts.cb?(error)
                    else
                        opts.cb?(undefined, if results?.length == 1 then {'value':from_json(results[0][0].value), 'timestamp':results[0][0].timestamp})
        else
            @cassandra.select
                table:'key_value'
                columns:['value']
                where:{name:@opts.name, key:to_json(opts.key)}
                cb:(error, results) =>
                    if error
                        opts.cb?(error)
                    else
                        opts.cb?(undefined, if results.length == 1 then from_json(results[0][0]))

    delete: (opts={}) ->
        opts = defaults(opts, key:undefined, cb:undefined)
        @cassandra.delete(table:'key_value', where:{name:@opts.name, key:to_json(opts.key)}, cb:opts.cb)

    delete_all: (opts={}) ->
        opts = defaults(opts,  cb:undefined)
        @cassandra.delete(table:'key_value', where:{name:@opts.name}, cb:opts.cb)

    length: (opts={}) ->
        opts = defaults(opts,  cb:undefined)
        @cassandra.count(table:'key_value', where:{name:@opts.name}, cb:opts.cb)

    all: (opts={}) =>
        opts = defaults(opts,  cb:undefined)
        @cassandra.select
            table:'key_value'
            columns:['key', 'value']
            where:{name:@opts.name}
            cb: (error, results) =>
                if error
                    opts.cb?(error)
                else
                    opts.cb?(undefined, [from_json(r[0]), from_json(r[1])] for r in results)

# Convert individual entries in columns from cassandra formats to what we
# want to use everywhere in Salvus. For example, uuids ficare converted to
# strings instead of their own special object type, since otherwise they
# convert to JSON incorrectly.

exports.from_cassandra = from_cassandra = (value, json) ->
    if not value?
        return undefined
    if value.toInt?
        value = value.toInt()   # newer version of node-cassandra-cql uses the Javascript long type
    else
        value = value.valueOf()
        if json
            value = from_json(value)
    return value

class exports.Cassandra extends EventEmitter
    constructor: (opts={}) ->    # cb is called on connect
        opts = defaults opts,
            hosts           : ['localhost']
            cb              : undefined
            keyspace        : undefined
            username        : undefined
            password        : undefined
            query_timeout_s : 30    # any query that doesn't finish after this amount of time (due to cassandra/driver *bugs*) will be retried a few times (same as consistency causing retries)
            query_max_retry : 3    # max number of retries
            consistency     : undefined
            verbose         : false # quick hack for debugging...
            conn_timeout_ms : 15000  # Maximum time in milliseconds to wait for a connection from the pool.

        @keyspace = opts.keyspace
        @query_timeout_s = opts.query_timeout_s
        @query_max_retry = opts.query_max_retry

        if opts.hosts.length == 1
            # the default consistency won't work if there is only one node.
            opts.consistency = 1

        @consistency = opts.consistency  # the default consistency (for now)

        #winston.debug("connect using: #{JSON.stringify(opts)}")  # DEBUG ONLY!! output contains sensitive info (the password)!!!
        @_opts = opts
        @connect()

    reconnect: (cb) =>
        winston.debug("reconnect to database server")
        if not @conn? or not @conn.shutdown?
            winston.debug("directly connecting")
            @connect(cb)
            return
        winston.debug("reconnect to database server -- first shutting down")
        @conn.shutdown (err) =>
            winston.debug("reconnect to database server -- shutdown returned #{err}")
            delete @conn
            @connect(cb)

    connect: (cb) =>
        winston.debug("connect: connecting to the database server")
        console.log("connecting...")
        opts = @_opts
        if @conn?
            @conn.shutdown?()
            delete @conn
        o =
            contactPoints         : opts.hosts
            keyspace              : opts.keyspace
            queryOptions          :
                consistency : @consistency
                prepare     : true
                fetchSize   : 150000  # TODO: this temporary - we need to rewrite various code in here to use paging, etc., which is now easy with new driver.
            socketOptions         :
                connectTimeout    : opts.conn_timeout_ms
        if opts.username? and opts.password?
            o.authProvider = new cql.auth.PlainTextAuthProvider(opts.username, opts.password)
        @conn = new Client(o)

        if opts.verbose
            @conn.on 'log', (level, message) =>
                winston.debug('database connection event: %s -- %j', level, message)

        @conn.on 'error', (err) =>
            winston.error(err.name, err.message)
            @emit('error', err)

        @conn.connect (err) =>
            if err
                winston.debug("failed to connect to database -- #{err}")
            else
                winston.debug("connected to database")
            opts.cb?(err, @)
            # CRITICAL -- we must not call the callback multiple times; note that this
            # connect event happens even on *reconnect*, which will happen when the
            # database connection gets dropped, e.g., due to restarting the database,
            # network issues, etc.
            opts.cb = undefined

            # this callback is for convenience when re-connecting
            cb?()
            cb=undefined

    _where: (where_key, vals, json=[]) ->
        where = "";
        for key, val of where_key
            equals_fallback = true
            for op in ['>', '<', '>=', '<=', '==', 'in', '']
                if op == '' and equals_fallback
                    x = val
                    op = '=='
                else
                    assert(val?, "val must be defined -- there's a bug somewhere: _where(#{to_json(where_key)}, #{to_json(vals)}, #{to_json(json)})")
                    x = val[op]
                if x?
                    if key in json
                        x2 = to_json(x)
                    else
                        x2 = x
                    if op != ''
                        equals_fallback = false
                    if op == '=='
                        op = '=' # for cassandra
                    where += "#{key} #{op} ?"
                    vals.push(x2)
                    where += " AND "
        return where.slice(0,-4)    # slice off final AND.

    _set: (properties, vals, json=[]) ->
        set = "";
        for key, val of properties
            if key in json
                val = to_json(val)
            if val?
                if misc.is_valid_uuid_string(val)
                    # The Helenus driver is completely totally
                    # broken regarding uuid's (their own UUID type
                    # doesn't work at all). (as of April 15, 2013)  - TODO: revisit this since I'm not using Helenus anymore.
                    # This is of course scary/dangerous since what if x2 is accidentally a uuid!
                    set += "#{key}=#{val},"
                else if typeof(val) != 'boolean'
                    set += "#{key}=?,"
                    vals.push(val)
                else
                    # TODO: here we work around a driver bug :-(
                    set += "#{key}=#{val},"
            else
                set += "#{key}=null,"
        return set.slice(0,-1)

    close: () ->
        @conn.close()
        @emit('close')

    ###########################################################################################
    # Set the count of entries in a table that we manually track.
    # (Note -- I tried implementing this by deleting the entry then updating and that made
    # the value *always* null no matter what.  So don't do that.)
    set_table_counter: (opts) =>
        opts = defaults opts,
            table : required
            value : required
            cb    : required

        current_value = undefined
        async.series([
            (cb) =>
                @get_table_counter
                    table : opts.table
                    cb    : (err, value) =>
                        current_value = value
                        cb(err)
            (cb) =>
                @update_table_counter
                    table : opts.table
                    delta : opts.value - current_value
                    cb    : cb
        ], opts.cb)

    # Modify the count of entries in a table that we manually track.
    # The default is to add 1.
    update_table_counter: (opts) =>
        opts = defaults opts,
            table : required
            delta : 1
            cb    : required
        query = "UPDATE counts SET count=count+? where table_name=?"
        @cql query, [new cql.types.Long(opts.delta), opts.table], opts.cb

    # Get count of entries in a table for which we manually maintain the count.
    get_table_counter: (opts) =>
        opts = defaults opts,
            table : required
            cb    : required  # cb(err, count)
        @select
            table     : 'counts'
            where     : {table_name : opts.table}
            columns   : ['count']
            objectify : false
            cb        : (err, result) =>
                if err
                    opts.cb(err)
                else
                    if result.length == 0
                        opts.cb(false, 0)
                    else
                        opts.cb(false, result[0][0])

    # Compute a count directly from the table.
    # ** This is highly inefficient in general and doesn't scale.  PAIN.  **
    count: (opts) ->
        opts = defaults opts,
            table       : required
            where       : {}
            consistency : undefined
            cb          : required   # cb(err, the count if delta=set=undefined)

        query = "SELECT COUNT(*) FROM #{opts.table}"
        vals = []
        if not misc.is_empty_object(opts.where)
            where = @_where(opts.where, vals)
            query += " WHERE #{where}"

        @cql query, vals, opts.consistency, (err, results) =>
            if err
                opts.cb(err)
            else
                opts.cb(undefined, from_cassandra(results[0].get('count')))

    update: (opts={}) ->
        opts = defaults opts,
            table     : required
            where     : required
            set       : {}
            ttl       : 0
            cb        : undefined
            consistency : undefined  # default...
            json      : []          # list of columns to convert to JSON
        vals = []
        set = @_set(opts.set, vals, opts.json)
        where = @_where(opts.where, vals, opts.json)
        @cql("UPDATE #{opts.table} USING ttl #{opts.ttl} SET #{set} WHERE #{where}", vals, opts.consistency, opts.cb)

    delete: (opts={}) ->
        opts = defaults opts,
            table : undefined
            where : {}
            thing : ''
            consistency : undefined  # default...
            cb    : undefined
        vals = []
        where = @_where(opts.where, vals)
        @cql("DELETE #{opts.thing} FROM #{opts.table} WHERE #{where}", vals, opts.consistency, opts.cb)

    select: (opts={}) =>
        opts = defaults opts,
            table           : required    # string -- the table to query
            columns         : required    # list -- columns to extract
            where           : undefined   # object -- conditions to impose; undefined = return everything
            cb              : required    # callback(error, results)
            objectify       : false       # if false results is a array of arrays (so less redundant); if true, array of objects (so keys redundant)
            limit           : undefined   # if defined, limit the number of results returned to this integer
            json            : []          # list of columns that should be converted from JSON format
            order_by        : undefined    # if given, adds an "ORDER BY opts.order_by"
            consistency     : undefined  # default...
            allow_filtering : false

        vals = []
        query = "SELECT #{opts.columns.join(',')} FROM #{opts.table}"
        if opts.where?
            where = @_where(opts.where, vals, opts.json)
            query += " WHERE #{where} "
        if opts.limit?
            query += " LIMIT #{opts.limit} "
        if opts.order_by?
            query += " ORDER BY #{opts.order_by} "

        if opts.allow_filtering
            query += " ALLOW FILTERING"
        @cql query, vals, opts.consistency, (error, results) =>
            if error
                opts.cb(error); return
            if opts.objectify
                x = (misc.pairs_to_obj([col,from_cassandra(r.get(col), col in opts.json)] for col in opts.columns) for r in results)
            else
                x = ((from_cassandra(r.get(col), col in opts.json) for col in opts.columns) for r in results)
            opts.cb(undefined, x)

    # Exactly like select (above), but gives an error if there is not exactly one
    # row in the table that matches the condition.  Also, this returns the one
    # rather than an array of length 0.
    select_one: (opts={}) =>
        cb = opts.cb
        opts.cb = (err, results) ->
            if err
                cb(err)
            else if results.length == 0
                cb("No row in table '#{opts.table}' matched condition '#{misc.to_json(opts.where)}'")
            else if results.length > 1
                cb("More than one row in table '#{opts.table}' matched condition '#{misc.to_json(opts.where)}'")
            else
                cb(false, results[0])
        @select(opts)

    cql: (query, vals, consistency, cb) =>
        if typeof vals == 'function'
            cb = vals
            vals = []
            consistency = undefined
        if typeof consistency == 'function'
            cb = consistency
            consistency = undefined
        if not consistency?
            consistency = @consistency

        winston.debug("cql: '#{misc.trunc(query,100)}', consistency=#{consistency}")
        @conn.execute query, vals, { consistency: consistency }, (err, results) =>
            if err?
                winston.error("cql ERROR: ('#{query}',params=#{misc.to_json(vals).slice(0,1024)}) error = #{err}")
            else
                results = results.rows
            cb?(err, results)

    cql0: (query, vals, consistency, cb) =>
        winston.debug("cql: '#{query}'")
        if typeof vals == 'function'
            cb = vals
            vals = []
            consistency = undefined
        if typeof consistency == 'function'
            cb = consistency
            consistency = undefined
        if not consistency?
            consistency = @consistency
        done = false  # set to true right before calling cb, so it can only be called once
        g = (c) =>
            @conn.execute query, vals, { consistency: consistency }, (error, results) =>
                if not error
                    error = undefined   # it comes back as null
                    if not results? # should never happen
                        error = "no error but no results"
                if error?
                    winston.error("Query cql('#{query}',params=#{misc.to_json(vals).slice(0,1024)}) caused a CQL error:\n#{error}")
                # TODO - this test for "ResponseError: Operation timed out" is HORRIBLE.
                # The 'any of its parents' is because often when the server is loaded it rejects requests sometimes
                # with "no permissions. ... any of its parents".
                if error? and ("#{error}".indexOf("peration timed out") != -1 or "#{error}".indexOf("any of its parents") != -1)
                    winston.error(error)
                    winston.error("... so (probably) re-doing query")
                    c(error)
                else
                    if not error
                        rows = results.rows
                    if not done
                        done = true
                        cb?(error, rows)
                    c()

        f = (c) =>
            failed = () =>
                m = "query #{query}, params=#{misc.to_json(vals).slice(0,1024)}, timed out with no response at all after #{@query_timeout_s} seconds -- will likely retry"
                winston.error(m)
                @reconnect (err) =>
                    c?(m)
                    c = undefined # ensure only called once
            _timer = setTimeout(failed, 1000*@query_timeout_s)
            g (err) =>
                clearTimeout(_timer)
                c?(err)
                c = undefined # ensure only called once

        # If a query fails due to "Operation timed out", then we will keep retrying, up to @query_max_retry times, with exponential backoff.
        # ** This is ABSOLUTELY critical, if we have a loaded system, slow nodes, want to use consistency level > 1, etc, **
        # since otherwise all our client code would have to do this...
        misc.retry_until_success
            f         : f
            max_tries : @query_max_retry
            max_delay : 15000
            factor    : 1.6
            cb        : (err) =>
                if err
                    err = "query failed even after #{@query_max_retry} attempts -- giving up -- #{err}"
                    winston.debug(err)
                if not done
                    done = true
                    cb?(err)

    key_value_store: (opts={}) -> # key_value_store(name:"the name")
        new KeyValueStore(@, opts)

    uuid_value_store: (opts={}) -> # uuid_value_store(name:"the name")
        new UUIDValueStore(@, opts)

    uuid_blob_store: (opts={}) -> # uuid_blob_store(name:"the name")
        new UUIDBlobStore(@, opts)

    chunked_storage: (opts) =>  # id=uuid
        opts.db = @
        return new ChunkedStorage(opts)

class exports.Salvus extends exports.Cassandra
    constructor: (opts={}) ->
        @_touch_project_cache = {}
        if not opts.keyspace?
            opts.keyspace = 'salvus'
        super(opts)

    #####################################
    # The cluster status monitor
    #####################################

    # returns array [{host:'10.x.y.z', ..., other data about compute node}, ...]
    compute_status: (opts={}) =>
        opts = defaults opts,
            cb : required
        @select_one
            table : 'monitor_last'
            columns : ['compute']
            json    : ['compute']
            cb      : (err, result) =>
                if err
                    opts.cb(err)
                else
                    opts.cb(undefined, result[0])

    #####################################
    # The log: we log important conceptually meaningful events
    # here.  This is something we will actually look at.
    #####################################
    log: (opts={}) ->
        opts = defaults opts,
            event : required    # string
            value : required    # object (will be JSON'd)
            ttl   : undefined
            cb    : undefined

        @update
            table :'central_log'
            set   : {event:opts.event, value:to_json(opts.value)}
            where : {'time':now()}
            cb    : opts.cb


    get_log: (opts={}) ->
        opts = defaults(opts,
            start_time : undefined
            end_time   : undefined
            cb         : required
        )

        where = {}
        # TODO -- implement restricting the range of times -- this
        # isn't trivial because I haven't implemented ranges in
        # @select yet, and I don't want to spend a lot of time on this
        # right now. maybe just write query using CQL.

        @select
            table   : 'central_log'
            where   : where
            columns : ['time', 'event', 'value']
            cb      : (error, results) ->
                if error
                    cb(error)
                else
                    cb(false, ({time:r[0], event:r[1], value:from_json(r[2])} for r in results))

    ##-- search


    # all_users: cb(err, array of {first_name:?, last_name:?, account_id:?, search:'names and email thing to search'})
    #
    # No matter how often all_users is called, it is only updated at most once every 5 minutes, since it is expensive
    # to scan the entire database, and the client will typically make numerous requests within seconds for
    # different searches.  When some time elapses and we get a search, if we have an old cached list in memory, we
    # use it and THEN start computing a new one -- so user queries are always answered nearly instantly, but only
    # repeated queries will give an up to date result.
    #
    # Of course, caching means that newly created accounts, or modified account names,
    # will not show up in searches for 1 minute.  That's
    # very acceptable.
    #
    # This obviously doesn't scale, and will need to be re-written to use some sort of indexing system, or
    # possibly only allow searching on email address, or other ways.  I don't know yet.
    #
    all_users: (cb) =>
        if @_all_users_fresh?
            cb(false, @_all_users); return
        if @_all_users?
            cb(false, @_all_users)
        if @_all_users_computing? and @_all_users?
            return
        @_all_users_computing = true
        @select
            table     : 'accounts'
            columns   : ['first_name', 'last_name', 'account_id']
            objectify : true
            consistency : 1     # since we really want optimal speed, and missing something temporarily is ok.
            limit     : 1000000  # TODO: probably start failing due to timeouts around 100K users (?) -- will have to cursor or query multiple times then?
            cb        : (err, results) =>
                if err and not @_all_users?
                    cb(err); return
                v = []
                for r in results
                    if not r.first_name?
                        r.first_name = ''
                    if not r.last_name?
                        r.last_name = ''
                    search = (r.first_name + ' ' + r.last_name).toLowerCase()
                    obj = {account_id : r.account_id, first_name:r.first_name, last_name:r.last_name, search:search}
                    v.push(obj)
                delete @_all_users_computing
                if not @_all_users?
                    cb(false,v)
                @_all_users = v
                @_all_users_fresh = true
                f = () =>
                    delete @_all_users_fresh
                setTimeout(f, 5*60000)   # cache for 5 minutes

    user_search: (opts) =>
        opts = defaults opts,
            query : required     # comma separated list of email addresses or strings such as 'foo bar' (find everything where foo and bar are in the name)
            limit : undefined    # limit on string queries; email query always returns 0 or 1 result per email address
            cb    : required     # cb(err, list of {account_id:?, first_name:?, last_name:?, email_address:?}), where the
                                 # email_address *only* occurs in search queries that are by email_address -- we do not reveal
                                 # email addresses of users queried by name.

        {string_queries, email_queries} = misc.parse_user_search(opts.query)

        results = []
        async.parallel([

            (cb) =>
                if email_queries.length == 0
                    cb(); return

                # do email queries -- with exactly two targeted db queries (even if there are hundreds of addresses)
                @select
                    table     : 'email_address_to_account_id'
                    where     : {email_address:{'in':email_queries}}
                    columns   : ['account_id']
                    objectify : false
                    cb        : (err, r) =>
                        if err
                            cb(err); return
                        if r.length == 0
                            cb(); return
                        @select
                            table     : 'accounts'
                            columns   : ['account_id', 'first_name', 'last_name', 'email_address']
                            where     : {'account_id':{'in':(x[0] for x in r)}}
                            objectify : true
                            cb        : (err, r) =>
                                if err
                                    cb(err)
                                else
                                    for x in r
                                        results.push(x)
                                    cb()

            (cb) =>
                # do all string queries
                if string_queries.length == 0 or (opts.limit? and results.length >= opts.limit)
                    # nothing to do
                    cb(); return

                @all_users (err, users) =>
                    if err
                        cb(err); return
                    match = (search) ->
                        for query in string_queries
                            matches = true
                            for q in query
                                if search.indexOf(q) == -1
                                    matches = false
                                    break
                            if matches
                                return true
                        return false
                    # SCALABILITY WARNING: In the worst case, this is a non-indexed linear search through all
                    # names which completely locks the server.  That said, it would take about
                    # 500,000 users before this blocks the server for *1 second*... at which point the
                    # database query to load all users into memory above (in @all_users) would take
                    # several hours.
                    # TODO: we should limit the number of search requests per user per minute, since this
                    # is a DOS vector.
                    for x in users
                        if match(x.search)
                            results.push(x)
                            if opts.limit? and results.length >= opts.limit
                                break
                    cb()

            ], (err) => opts.cb(err, results))


    account_ids_to_usernames: (opts) =>
        opts = defaults opts,
            account_ids : required
            cb          : required # (err, mapping {account_id:{first_name:?, last_name:?}})
        if opts.account_ids.length == 0 # easy special case -- don't waste time on a db query
            opts.cb(false, [])
            return
        @select
            table     : 'accounts'
            columns   : ['account_id', 'first_name', 'last_name']
            where     : {account_id:{'in':opts.account_ids}}
            objectify : true
            cb        : (err, results) =>
                if err
                    opts.cb?(err)
                else
                    v = {}
                    for r in results
                        v[r.account_id] = {first_name:r.first_name, last_name:r.last_name}
                    opts.cb(err, v)

    #####################################
    # Managing compute servers
    #####################################
    # if keyspace is test, and there are no compute servers, returns
    # 'localhost' no matter what, since often when testing we don't
    # put an entry in the database.
    running_compute_servers: (opts={}) ->
        opts = defaults opts,
            cb   : required
            min_score : MIN_SCORE

        @select
            table   : 'compute_servers'
            columns : ['host', 'score']
            where   : {running:true, dummy:true}
            allow_filtering : true
            cb      : (err, results) =>
                if results.length == 0 and @keyspace == 'test'
                    # This is used when testing the compute servers
                    # when not run as a daemon so there is not entry
                    # in the database.
                    opts.cb(err, [{host:'localhost', score:0}])
                else
                    opts.cb(err, {host:x[0], score:x[1]} for x in results when x[1]>=opts.min_score)

    # cb(error, random running sage server) or if there are no running
    # sage servers, then cb(undefined).  We only consider servers whose
    # score is strictly greater than opts.min_score.
    random_compute_server: (opts={}) ->
        opts = defaults opts,
            cb        : required

        @running_compute_servers
            cb   : (error, res) ->
                if not error and res.length == 0
                    opts.cb("no compute servers")
                else
                    opts.cb(error, misc.random_choice(res))

    # Adjust the score on a compute server.  It's possible that two
    # different servers could change this at the same time, thus
    # messing up the score slightly.  However, the score is a rough
    # heuristic, not a bank account balance, so I'm not worried.
    # TODO: The score algorithm -- a simple integer delta -- is
    # trivial; there is a (provably?) better approach used by
    # Cassandra that I'll implement in the future.
    score_compute_server: (opts) ->
        opts = defaults opts,
            host  : required
            delta : required
            cb    : undefined
        new_score = undefined
        async.series([
            (cb) =>
                @select
                    table   : 'compute_servers'
                    columns : ['score']
                    where   : {host:opts.host, dummy:true}
                    cb      : (err, results) ->
                        if err
                            cb(err)
                            return
                        if results.length == 0
                            cb("No compute server '#{opts.host}'")
                        new_score = results[0][0] + opts.delta
                        cb()
            (cb) =>
                if new_score >= MIN_SCORE and new_score <= MAX_SCORE
                    @update
                        table : 'compute_servers'
                        set   : {score : new_score}
                        where : {host  : opts.host, dummy:true}
                        cb    : cb
                else
                    # new_score is outside the allowed range, so we do nothing.
                    cb()
        ], opts.cb)

    #####################################
    # Account Management
    #####################################
    is_email_address_available: (email_address, cb) =>
        @count
            table : "email_address_to_account_id"
            where :{email_address : misc.lower_email_address(email_address)}
            cb    : (error, cnt) =>
                if error
                   cb(error)
                else
                   cb(null, cnt==0)

    create_account: (opts={}) ->
        opts = defaults opts,
            first_name    : required
            last_name     : required
            email_address : required
            password_hash : required
            cb            : required

        account_id = uuid.v4()
        opts.email_address = misc.lower_email_address(opts.email_address)   # canonicalize the email address
        async.series([
            # verify that account doesn't already exist
            (cb) =>
                @select
                    table : 'email_address_to_account_id'
                    columns : ['account_id']
                    where : {'email_address':opts.email_address}
                    cb    : (err, results) =>
                        if err
                            cb(err)
                        else if results.length > 0
                            cb("account with email address '#{opts.email_address}' already exists")
                        else
                            cb()
            # create account
            (cb) =>
                @update
                    table :'accounts'
                    set   :
                        first_name    : opts.first_name
                        last_name     : opts.last_name
                        email_address : opts.email_address
                        password_hash : opts.password_hash
                        created       : now()
                    where : {account_id:account_id}
                    cb    : cb
            (cb) =>
                @update
                    table : 'email_address_to_account_id'
                    set   : {account_id : account_id}
                    where : {email_address: opts.email_address}
                    cb    : cb
            # add 1 to the "number of accounts" counter
            (cb) =>
                @update_table_counter
                    table : 'accounts'
                    delta : 1
                    cb    : cb
        ], (err) =>
            if err
                opts.cb(err)
            else
                opts.cb(false, account_id)
        )

    # This should never have to be run; however, it could be useful to run it periodically "just in case".
    # I wrote this when migrating the database to avoid secondary indexes.
    update_email_address_to_account_id_table: (cb) =>
        @select
            table: 'accounts'
            limit: 10000000  # effectively unlimited...
            columns: ['email_address', 'account_id']
            objectify: false
            cb: (err, results) =>
                console.log("Got full table with #{results.length} entries.  Now populating email_address_to_account_id table....")
                t = {}
                f = (r, cb) =>
                     if not r[0]? or not r[1]?
                          console.log("skipping", r)
                          cb()
                          return
                     if t[r[0]]?
                         console.log("WARNING: saw the email address '#{r[0]}' more than once.  account_id=#{r[1]} ")
                     t[r[0]] = r[1]
                     @update
                         table : 'email_address_to_account_id'
                         set   : {account_id: r[1]}
                         where : {email_address: r[0]}
                         cb    : cb
                async.map results, f, (err) =>
                    console.log("#{misc.len(t)} distinct email addresses")
                    if err
                        console.log("error updating...",err)
                        cb(err)
                    else
                        @set_table_counter
                            table : 'accounts'
                            value : misc.len(t)
                            cb    : cb

    # A *one-off* computation!  For when we canonicalized email addresses to be lower case.
    lowercase_email_addresses: (cb) =>
        ###
        Algorithm:
         - get list of all pairs (account_id, email_address)
         - use to make map  {lower_email_address:[[email_address, account_id], ... }
         - for each key of that map:
               - if multiple addresses, query db to see which was used most recently
               - set accounts record with given account_id to lower_email_address
               - set email_address_to_account_id --> accounts mapping to map lower_email_address to account_id.
        ###
        dbg = (m) -> console.log("lowercase_email_addresses: #{m}")
        dbg()
        @select
            table     : 'accounts'
            limit     : 10000000  # effectively unlimited...
            columns   : ['email_address', 'account_id']
            objectify : false
            cb: (err, results) =>
                dbg("There are #{results.length} accounts.")
                results.sort()
                t = {}
                for r in results
                    if r[0]?
                        k = r[0].toLowerCase()
                        if not t[k]?
                            t[k] = []
                        t[k].push(r)
                total = misc.len(t)
                cnt = 1
                dbg("There are #{total} distinct lower case email addresses.")
                f = (k, cb) =>
                    dbg("#{k}: #{cnt}/#{total}"); cnt += 1
                    v = t[k]
                    account_id = undefined
                    async.series([
                        (c) =>
                            if v.length == 1
                                dbg("#{k}: easy case of only one account")
                                account_id = v[0][1]
                                c(true)
                            else
                                dbg("#{k}: have to deal with #{v.length} accounts")
                                c()
                        (c) =>
                            @select
                                table    : 'successful_sign_ins'
                                columns  : ['time','account_id']
                                where    : {'account_id':{'in':(x[1] for x in v)}}
                                order_by : 'time'
                                cb       : (e, results) =>
                                    if e
                                        c(e)
                                    else
                                        if results.length == 0   # never logged in... -- so just take one arbitrarily
                                            account_id = v[0][1]
                                        else
                                            account_id = results[results.length-1][1]
                                        c()
                    ], (ignore) =>
                        if account_id?
                            async.series([
                                (c) =>
                                    @update
                                        table : 'accounts'
                                        set   : {'email_address': k}
                                        where : {'account_id': account_id}
                                        cb    : c
                                (c) =>
                                    @update
                                        table : 'email_address_to_account_id'
                                        set   : {'account_id': account_id}
                                        where : {'email_address': k}
                                        cb    : c
                            ], cb)
                        else
                            cb("unable to determine account for email '#{k}'")
                    )
                async.mapLimit misc.keys(t), 5, f, (err) =>
                    dbg("done -- err=#{err}")


    # Delete the account with given id, and
    # remove the entry in the email_address_to_account_id table
    # corresponding to this account, if indeed the entry in that
    # table does map to this account_id.  This should only ever be
    # used for testing purposes, since there's no reason to ever
    # delete an account record -- doing so would mean throwing
    # away valuable information, e.g., there could be projects, etc.,
    # that only refer to the account_id, and we must know what the
    # account_id means.
    # Returns an error if the account doesn't exist.
    delete_account: (opts) =>
        opts = defaults opts,
            account_id : required
            cb         : required
        email_address = undefined
        async.series([
            # find email address associated to this account
            (cb) =>
                @get_account
                    account_id : opts.account_id
                    columns    : ['email_address']
                    cb         : (err, account) =>
                        if err
                            cb(err)
                        else
                            email_address = account.email_address
                            cb()
            # delete entry in the email_address_to_account_id table
            (cb) =>
                @select
                    table   : 'email_address_to_account_id'
                    columns : ['account_id']
                    where   : {email_address: email_address}
                    cb      : (err, results) =>
                        if err
                            cb(err)
                        else if results.length > 0 and results[0][0] == opts.account_id
                            # delete entry of that table
                            @delete
                                table : 'email_address_to_account_id'
                                where : {email_address: email_address}
                                cb    : cb
                        else
                            # deleting a "spurious" account that isn't mapped to by email_address_to_account_id table,
                            # so nothing to do here.
                            cb()
            # everything above worked, so now delete the actual account
            (cb) =>
                @delete
                    table : "accounts"
                    where : {account_id : opts.account_id}
                    cb    : cb
            # subtract 1 from the "number of accounts" counter
            (cb) =>
                @update_table_counter
                    table : 'accounts'
                    delta : -1
                    cb    : cb

        ], opts.cb)


    get_account: (opts={}) =>
        opts = defaults opts,
            cb            : required
            email_address : undefined     # provide either email or account_id (not both)
            account_id    : undefined
            consistency   : 1
            columns       : ['account_id', 'password_hash',
                             'first_name', 'last_name', 'email_address',
                             'default_system', 'evaluate_key',
                             'email_new_features', 'email_maintenance', 'enable_tooltips',
                             'autosave', 'terminal', 'editor_settings', 'other_settings',
                             'groups']

        account = undefined
        if opts.email_address?
            opts.email_address = misc.lower_email_address(opts.email_address)
        async.series([
            (cb) =>
                if opts.account_id?
                    cb()
                else if not opts.email_address?
                    cb("get_account -- the email_address or account_id must be specified")
                else
                    @select
                        table       : 'email_address_to_account_id'
                        where       : {email_address:opts.email_address}
                        columns     : ['account_id']
                        objectify   : false
                        consistency : opts.consistency
                        cb          : (err, results) =>
                            if err
                                cb(err)
                            else if results.length == 0
                                cb("There is no account with email address #{opts.email_address}.")
                            else
                                # success!
                                opts.account_id = results[0][0]
                                cb()
            (cb) =>
                @select
                    table       : 'accounts'
                    where       : {account_id : opts.account_id}
                    columns     : opts.columns
                    objectify   : true
                    json        : ['terminal', 'editor_settings', 'other_settings']
                    consistency : opts.consistency
                    cb          : (error, results) ->
                        if error
                            cb(error)
                        else if results.length == 0
                            cb("There is no account with account_id #{opts.account_id}.")
                        else
                            account = results[0]
                            if not account.groups?
                                account.groups = []  # make it an array in all cases.
                            cb()
        ], (err) =>
            opts.cb(err, account)
        )

    # check whether or not a user is banned
    is_banned_user: (opts) =>
        opts = defaults opts,
            email_address : undefined
            account_id    : undefined
            cb            : required    # cb(err, true if banned; false if not banned)
        if not opts.email_address? and not opts.account_id?
            opts.cb("is_banned_user -- email_address or account_id must be given")
            return
        if opts.email_address?
            opts.email_address = misc.lower_email_address(opts.email_address)
        dbg = (m) -> winston.debug("user_is_banned(email_address=#{opts.email_address},account_id=#{opts.account_id}): #{m}")
        banned_accounts = undefined
        email_address = undefined
        async.series([
            (cb) =>
                if @_account_is_banned_cache?
                    banned_accounts = @_account_is_banned_cache
                    cb()
                else
                    dbg("filling cache")
                    @select
                        table       : 'banned_email_addresses'
                        columns     : ['email_address']
                        consistency : 1
                        cb          : (err, results) =>
                            if err
                                cb(err); return
                            @_account_is_banned_cache = {}
                            for x in results
                                @_account_is_banned_cache[x] = true
                            banned_accounts = @_account_is_banned_cache
                            f = () =>
                                delete @_account_is_banned_cache
                            setTimeout(f, 7*24*60*60000)    # cache db lookups for a long time (basically next restart) -- right now not used much anyways, due to no account verification.
                            cb()
            (cb) =>
                if opts.email_address?
                    email_address = opts.email_address
                    cb()
                else
                    dbg("determining email address from account id")
                    @select_one
                        table       : 'accounts'
                        columns     : ['email_address']
                        consistency : 1
                        cb          : (err, result) =>
                            if err
                                cb(err); return
                            email_address = result[0]
                            cb()
        ], (err) =>
            if err
                opts.cb(err)
            else
                # finally -- check if is banned
                opts.cb(undefined, banned_accounts[misc.canonicalize_email_address(email_address)]==true)
        )

    ban_user: (opts) =>
        opts = defaults opts,
            email_address : undefined
            cb            : undefined
        @update
            table  : 'banned_email_addresses'
            set    : {dummy : true}
            where  : {email_address : misc.canonicalize_email_address(opts.email_address)}
            cb     : (err) => opts.cb?(err)

    account_exists: (opts) =>
        opts = defaults opts,
            email_address : required
            cb            : required   # cb(err, account_id or false) -- true if account exists; err = problem with db connection...

        opts.email_address = misc.lower_email_address(opts.email_address)   # canonicalize the email address
        @select
            table     : 'email_address_to_account_id'
            where     : {email_address:opts.email_address}
            columns   : ['account_id']
            objectify : false
            cb        : (err, results) =>
                if err
                    opts.cb(err)
                else
                    if results.length == 0
                        opts.cb(false, false)
                    else
                        opts.cb(false, results[0][0])

    account_creation_actions: (opts) =>
        opts = defaults opts,
            email_address : required
            action        : undefined   # if given, adds this action; if not given cb(err, [array of actions])
            ttl           : undefined
            cb            : required
        if opts.action?
            if opts.ttl?
                ttl = "USING ttl #{opts.ttl}"
            else
                ttl = ""
            query = "UPDATE account_creation_actions #{ttl} SET actions=actions+{'#{misc.to_json(opts.action)}'} WHERE email_address=?"
            @cql(query, [opts.email_address], opts.cb)
        else
            @select
                table     : 'account_creation_actions'
                where     : {email_address: opts.email_address}
                columns   : ['actions']
                objectify : false
                cb        : (err, results) =>
                    if err
                        opts.cb(err)
                    else
                        if results.length == 0
                            opts.cb(undefined, [])
                        else
                            console.log(results[0][0])
                            opts.cb(false, (misc.from_json(r) for r in results[0][0]))

    update_account_settings: (opts={}) ->
        opts = defaults opts,
            account_id : required
            settings   : required
            cb         : required

        async.series([
            # We treat email separately, since email must be unique,
            # but Cassandra does not have a unique col feature.
            (cb) =>
                if opts.settings.email_address?
                    @change_email_address
                        account_id    : opts.account_id
                        email_address : opts.settings.email_address
                        cb : (error, result) ->
                            if error
                                opts.cb(error)
                                cb(true)
                            else
                                delete opts.settings.email_address
                                cb()
                else
                    cb()
            # make all the non-email changes
            (cb) =>
                @update
                    table      : 'accounts'
                    where      : {'account_id':opts.account_id}
                    set        : opts.settings
                    json       : ['terminal', 'editor_settings', 'other_settings']
                    cb         : (error, result) ->
                        opts.cb(error, result)
                        cb()
        ])


    change_password: (opts={}) ->
        opts = defaults(opts,
            account_id    : required
            password_hash : required
            cb            : undefined
        )
        @update(
            table   : 'accounts'
            where   : {account_id:opts.account_id}
            set     : {password_hash: opts.password_hash}
            cb      : opts.cb
        )

    # Change the email address, unless the email_address we're changing to is already taken.
    change_email_address: (opts={}) =>
        opts = defaults opts,
            account_id    : required
            email_address : required
            cb            : undefined

        dbg = (m) -> winston.debug("change_email_address(#{opts.account_id}, #{opts.email_address}): #{m}")
        dbg()

        orig_address = undefined
        opts.email_address = misc.lower_email_address(opts.email_address)

        async.series([
            (cb) =>
                dbg("verify that email address is not already taken")
                @count
                    table   : 'email_address_to_account_id'
                    where   : {email_address : opts.email_address}
                    cb      : (err, result) =>
                        if err
                            cb(err); return
                        if result > 0
                            cb('email_already_taken')
                        else
                            cb()
            (cb) =>
                dbg("get old email address")
                @select_one
                    table : 'accounts'
                    where : {account_id : opts.account_id}
                    columns : ['email_address']
                    cb      : (err, result) =>
                        if err
                            cb(err)
                        else
                            orig_address = result[0]
                            cb()
            (cb) =>
                dbg("change in accounts table")
                @update
                    table   : 'accounts'
                    where   : {account_id    : opts.account_id}
                    set     : {email_address : opts.email_address}
                    cb      : cb
            (cb) =>
                dbg("add new one")
                @update
                    table : 'email_address_to_account_id'
                    set   : {account_id : opts.account_id}
                    where : {email_address: opts.email_address}
                    cb    : cb
            (cb) =>
                dbg("delete old address in email_address_to_account_id")
                @delete
                    table : 'email_address_to_account_id'
                    where : {email_address: orig_address}
                    cb    : (ignored) => cb()

        ], (err) =>
            if err == "nothing to do"
                opts.cb?()
            else
                opts.cb?(err)
        )



    #####################################
    # User Feedback
    #####################################
    report_feedback: (opts={}) ->
        opts = defaults opts,
            account_id:  undefined
            category:        required
            description: required
            data:        required
            nps:         undefined
            cb:          undefined

        feedback_id = uuid.v4()
        time = now()
        @update
            table : "feedback"
            where : {feedback_id:feedback_id}
            json  : ['data']
            set   : {account_id:opts.account_id, time:time, category: opts.category, description: opts.description, nps:opts.nps, data:opts.data}
            cb    : opts.cb

    get_all_feedback_from_user: (opts={}) ->
        opts = defaults opts,
            account_id : required
            cb         : undefined

        @select
            table     : "feedback"
            where     : {account_id:opts.account_id}
            columns   : ['time', 'category', 'data', 'description', 'notes', 'url']
            json      : ['data']
            objectify : true
            cb        : opts.cb

    get_all_feedback_of_category: (opts={}) ->
        opts = defaults opts,
            category      : required
            cb        : undefined
        @select
            table     : "feedback"
            where     : {category:opts.category}
            columns   : ['time', 'account_id', 'data', 'description', 'notes', 'url']
            json      : ['data']
            objectify : true
            cb        : opts.cb



    #############
    # Tracking file access
    ############
    log_file_access: (opts) =>
        opts = defaults opts,
            project_id : required
            account_id : required
            filename   : required
            cb         : undefined
        date = new Date()
        @update
            table : 'file_access_log'
            set   :
                filename : opts.filename
            where :
                day        : date.toISOString().slice(0,10) # this is a string
                timestamp  : date
                project_id : opts.project_id
                account_id : opts.account_id
            cb : opts.cb

    # Get all files accessed in all projects
    get_file_access: (opts) =>
        opts = defaults opts,
            day    : required    # GMT string year-month-day
            start  : undefined   # start time on that day in iso format
            end    : undefined   # end time on that day in iso format
            cb     : required
        where = {day:opts.day, timestamp:{}}
        if opts.start?
            where.timestamp['>='] = opts.start
        if opts.end?
            where.timestamp['<='] = opts.end
        if misc.len(where.timestamp) == 0
            delete where.timestamp
        console.log("where = #{misc.to_json(where)}")
        @select
            table   : 'file_access_log'
            columns : ['day', 'timestamp', 'account_id', 'project_id', 'filename']
            where   : where
            cb      : opts.cb


    #############
    # Projects
    ############
    #
    get_gitconfig: (opts) ->
        opts = defaults opts,
            account_id : required
            cb         : required
        @select
            table      : 'accounts'
            columns    : ['gitconfig', 'first_name', 'last_name', 'email_address']
            objectify  : true
            where      : {account_id : opts.account_id}
            cb         : (err, results) ->
                if err
                    opts.cb(err)
                else if results.length == 0
                    opts.cb("There is no account with id #{opts.account_id}.")
                else
                    r = results[0]
                    if r.gitconfig? and r.gitconfig.length > 0
                        gitconfig = r.gitconfig
                    else
                        # Make a github out of first_name, last_name, email_address
                        gitconfig = "[user]\n    name = #{r.first_name} #{r.last_name}\n    email = #{r.email_address}\n"
                    opts.cb(false, gitconfig)

    get_project_data: (opts) =>
        opts = defaults opts,
            project_id  : required
            columns     : required
            objectify   : false
            consistency : undefined
            cb          : required
        @select_one
            table       : 'projects'
            where       : {project_id: opts.project_id}
            columns     : opts.columns
            objectify   : opts.objectify
            consistency : opts.consistency
            cb          : opts.cb

    get_public_paths: (opts) =>
        opts = defaults opts,
            project_id  : required
            consistency : undefined
            cb          : required
        @select
            table       : 'public_paths'
            where       : {project_id: opts.project_id}
            columns     : ['path', 'description']
            objectify   : true
            consistency : opts.consistency
            cb          : opts.cb

    publish_path: (opts) =>
        opts = defaults opts,
            project_id  : required
            path        : required
            description : required
            cb          : required
        @update
            table       : 'public_paths'
            where       : {project_id: opts.project_id, path:opts.path}
            set         : {description: opts.description}
            cb          : opts.cb

    unpublish_path: (opts) =>
        opts = defaults opts,
            project_id  : required
            path        : required
            cb          : required
        @delete
            table       : 'public_paths'
            where       : {project_id: opts.project_id, path:opts.path}
            cb          : opts.cb

    # get map {project_group:[{account_id:?,first_name:?,last_name:?}], ...}
    get_project_users: (opts) =>
        opts = defaults opts,
            project_id : required
            groups     : PROJECT_GROUPS
            cb         : required

        groups = undefined
        names = undefined
        async.series([
            # get account_id's of all users
            (cb) =>
                @get_project_data
                    project_id : opts.project_id
                    columns    : opts.groups
                    objectify  : false
                    cb         : (err, _groups) =>
                        if err
                            cb(err)
                        else
                            groups = _groups
                            for i in [0...groups.length]
                                if not groups[i]?
                                    groups[i] = []
                            cb()
            # get names of users
            (cb) =>
                v = _.flatten(groups)
                @account_ids_to_usernames
                    account_ids : v
                    cb          : (err, _names) =>
                        names = _names
                        cb(err)
        ], (err) =>
            if err
                opts.cb(err)
            else
                r = {}
                i = 0
                for g in opts.groups
                    r[g] = []
                    for account_id in groups[i]
                        x = names[account_id]
                        if x?
                            r[g].push({account_id:account_id, first_name:x.first_name, last_name:x.last_name})
                    i += 1
                opts.cb(false, r)
        )

    # linked projects
    linked_projects: (opts) =>
        opts = defaults opts,
            project_id : required
            add        : undefined   # array if given
            remove     : undefined   # array if given
            cb         : required    # if neither add nor remove are specified, then cb(err, list of linked project ids)
        list = undefined
        dbg = (m) -> winston.debug("linked_projects: #{m}")
        async.series([
            (cb) =>
                if not opts.add?
                    cb(); return
                for x in opts.add
                    if not misc.is_valid_uuid_string(x)
                        cb("invalid uuid '#{x}'")
                        return
                #TODO: I don't know how to put variable number of params into a @cql call
                query = "UPDATE projects SET linked_projects=linked_projects+{#{opts.add.join(',')}} where project_id=?"
                #dbg("add query: #{query}")
                @cql(query, [opts.project_id], cb)
            (cb) =>
                if not opts.remove?
                    cb(); return
                for x in opts.remove
                    if not misc.is_valid_uuid_string(x)
                        cb("invalid uuid '#{x}'")
                        return
                query = "UPDATE projects SET linked_projects=linked_projects-{#{opts.remove.join(',')}} where project_id=?"
                #dbg("remove query: #{query}")
                @cql(query, [opts.project_id], cb)
            (cb) =>
                if opts.add? or opts.remove?
                    cb(); return
                @select_one
                    table   : 'projects'
                    where   : {'project_id':opts.project_id}
                    columns : ['linked_projects']
                    objectify : false
                    cb      : (err, result) =>
                        if err
                            cb(err)
                        else
                            list = result[0]
                            cb()
        ], (err) => opts.cb(err, list))

    # Set last_edited for this project to right now, and possibly update its size.
    # It is safe and efficient to call this function very frequently since it will
    # actually hit the database at most once every 30 seconds (per project).  In particular,
    # once called, it ignores subsequent calls for the same project for 30 seconds.
    touch_project: (opts) ->
        opts = defaults opts,
            project_id : required
            size       : undefined
            cb         : undefined
        winston.debug("touch_project: #{opts.project_id}")
        id = opts.project_id
        tm = @_touch_project_cache[id]
        if tm?
            if misc.walltime(tm) < 30
                opts.cb?()
                return
            else
                delete @_touch_project_cache[id]

        @_touch_project_cache[id] = misc.walltime()

        set = {last_edited: now()}
        if opts.size
            set.size = opts.size

        @update
            table : 'projects'
            set   : set
            where : {project_id : opts.project_id}
            cb    : (err, result) =>
                if err
                    opts.cb?(err); return
                f = (t, cb) =>
                    @update
                        table : 'recently_modified_projects'
                        set   : {dummy:true}
                        where : {ttl:t.desc, project_id : opts.project_id}
                        # This ttl should be substantially bigger than the snapshot_interval
                        # in snap.coffee, but not too long to make the query and search of
                        # everything in this table slow.
                        ttl   : t.ttl
                        cb    : cb
                async.map(RECENT_TIMES_ARRAY, f, (err) -> opts.cb?(err))

    create_project: (opts) ->
        opts = defaults opts,
            project_id  : required
            account_id  : required  # owner
            title       : required
            description : undefined  # optional
            public      : required
            cb          : required

        async.series([
            # add entry to projects table
            (cb) =>
                @update
                    table : 'projects'
                    set   :
                        account_id  : opts.account_id
                        title       : opts.title
                        last_edited : now()
                        description : opts.description
                        public      : opts.public
                        created     : now()
                    where : {project_id: opts.project_id}
                    cb    : (error, result) ->
                        if error
                            opts.cb(error)
                            cb(true)
                        else
                            cb()
            # add account_id as owner of project (modifies both project and account records).
            (cb) =>
                @add_user_to_project
                    project_id : opts.project_id
                    account_id : opts.account_id
                    group      : 'owner'
                    cb         : cb
            # increment number of projects counter
            (cb) =>
                @update_table_counter
                    table : 'projects'
                    delta : 1
                    cb    : cb
        ], opts.cb)

    undelete_project: (opts) =>
        opts = defaults opts,
            project_id  : required
            cb          : undefined
        @update
            table : 'projects'
            set   : {deleted:false}
            where : {project_id : opts.project_id}
            cb    : opts.cb

    delete_project: (opts) =>
        opts = defaults opts,
            project_id  : required
            cb          : undefined
        @update
            table : 'projects'
            set   : {deleted:true}
            where : {project_id : opts.project_id}
            cb    : opts.cb

    hide_project_from_user: (opts) =>
        opts = defaults opts,
            project_id : required
            account_id : required
            cb         : undefined
        async.parallel([
            (cb) =>
                query = "UPDATE projects SET hide_from_accounts=hide_from_accounts+{#{opts.account_id}} WHERE project_id=?"
                @cql(query, [opts.project_id], cb)
            (cb) =>
                query = "UPDATE accounts SET hidden_projects=hidden_projects+{#{opts.project_id}} WHERE account_id=?"
                @cql(query, [opts.account_id], cb)
        ], (err) => opts.cb?(err))

    unhide_project_from_user: (opts) =>
        opts = defaults opts,
            project_id : required
            account_id : required
            cb         : undefined
        async.parallel([
            (cb) =>
                query = "UPDATE projects SET hide_from_accounts=hide_from_accounts-{#{opts.account_id}} WHERE project_id=?"
                @cql(query, [opts.project_id], cb)
            (cb) =>
                query = "UPDATE accounts SET hidden_projects=hidden_projects-{#{opts.project_id}} WHERE account_id=?"
                @cql(query, [opts.account_id], cb)
        ], (err) => opts.cb?(err))

    # Make it so the user with given account id is listed as a(n invited) collaborator or viewer
    # on the given project.  This modifies a set collection on the project *and* modifies a
    # collection on that account.
    # There is no attempt to make sure a user is in only one group at a time -- client code must do that.
    _verify_project_user: (opts) =>
        # We have to check that is a uuid and use strings, rather than params, due to limitations of the
        # Helenus driver.  CQL injection...
        if not misc.is_valid_uuid_string(opts.project_id) or not misc.is_valid_uuid_string(opts.account_id)
            return "invalid uuid"
        else if opts.group not in PROJECT_GROUPS
            return "invalid group"
        else
            return null

    add_user_to_project: (opts) =>
        opts = defaults opts,
            project_id : required
            account_id : required
            group      : required  # see PROJECT_GROUPS above
            cb         : required  # cb(err)
        e = @_verify_project_user(opts)
        if e
            opts.cb(e); return
        async.series([
            # add account_id to the project's set of users (for the given group)
            (cb) =>
                query = "UPDATE projects SET #{opts.group}=#{opts.group}+{#{opts.account_id}} WHERE project_id=?"
                @cql(query, [opts.project_id], cb)
            # add project_id to the set of projects (for the given group) for the user's account
            (cb) =>
                query = "UPDATE accounts SET #{opts.group}=#{opts.group}+{#{opts.project_id}} WHERE account_id=?"
                @cql(query, [opts.account_id], cb)
        ], opts.cb)

    remove_user_from_project: (opts) =>
        opts = defaults opts,
            project_id : required
            account_id : required
            group      : required  # see PROJECT_GROUPS above
            cb         : required  # cb(err)
        e = @_verify_project_user(opts)
        if e
            opts.cb(e); return
        async.series([
            # remove account_id from the project's set of users (for the given group)
            (cb) =>
                query = "UPDATE projects SET #{opts.group}=#{opts.group}-{#{opts.account_id}} WHERE project_id=?"
                @cql(query, [opts.project_id], cb)
            # remove project_id from the set of projects (for the given group) for the user's account
            (cb) =>
                query = "UPDATE accounts SET #{opts.group}=#{opts.group}-{#{opts.project_id}} WHERE account_id=?"
                @cql(query, [opts.account_id], cb)
        ], opts.cb)

    # SINGLE USE ONLY:
    # This code below is *only* used for migrating from the project_users table to a
    # denormalized representation using the PROJECT_GROUPS collections.
    migrate_from_deprecated_project_users_table: (cb) =>
        results = undefined
        async.series([
            (cb) =>
                console.log("Load entire project_users table into memory")
                @select
                    table     : 'project_users'
                    limit     : 1000000
                    columns   : ['project_id', 'account_id', 'mode', 'state']
                    objectify : true
                    cb        : (err, _results) =>
                        results = _results
                        cb(err)
            (cb) =>
                console.log("For each row in the table, call add_user_to_project")
                f = (r, c) =>
                    console.log(r)
                    group = r.mode
                    if r.state == 'invited'
                        group = 'invited_' + group
                    @add_user_to_project
                        project_id : r.project_id
                        account_id : r.account_id
                        group      : group
                        cb         : c
                # note -- this does all bazillion in parallel :-)
                async.map(results, f, cb)
        ], cb)

    # cb(err, true if project is public)
    project_is_public: (opts) =>
        opts = defaults opts,
            project_id  : required
            consistency : undefined
            cb          : required  # cb(err, is_public)
        @get_project_data
            project_id  : opts.project_id
            columns     : ['public']
            objectify   : false
            consistency : opts.consistency
            cb          : (err, result) ->
                if err
                    opts.cb(err)
                else
                    opts.cb(false, result[0])


    # cb(err, true if user is in one of the groups)
    user_is_in_project_group: (opts) =>
        opts = defaults opts,
            project_id  : required
            account_id  : required
            groups      : required  # array of elts of PROJECT_GROUPS above
            consistency : undefined
            cb          : required  # cb(err)
        @get_project_data
            project_id  : opts.project_id
            columns     : opts.groups
            objectify   : false
            consistency : opts.consistency
            cb          : (err, result) ->
                if err
                    opts.cb(err)
                else
                    opts.cb(undefined, opts.account_id in _.flatten(result))

    # all id's of projects having anything to do with the given account
    get_project_ids_with_user: (opts) =>
        opts = defaults opts,
            account_id : required
            cb         : required      # opts.cb(err, [project_id, project_id, project_id, ...])
        @select_one
            table     : 'accounts'
            columns   : PROJECT_GROUPS
            where     : {account_id : opts.account_id}
            objectify : false
            cb        : (err, result) ->
                if err
                    opts.cb(err); return
                v = []
                for r in result
                    if r?
                        v = v.concat(r)
                opts.cb(undefined, v)

    get_hidden_project_ids: (opts) =>
        opts = defaults opts,
            account_id : required
            cb         : required    # cb(err, mapping with keys the project_ids and values true)
        @select_one
            table : 'accounts'
            columns : ['hidden_projects']
            where   : {account_id : opts.account_id}
            cb      : (err, r) =>
                if err
                    opts.cb(err)
                else
                    v = {}
                    if r[0]?
                        for x in r[0]
                            v[x] = true
                    opts.cb(undefined, v)

    # gets all projects that the given account_id is a user on (owner,
    # collaborator, or viewer); gets all data about them, not just id's
    get_projects_with_user: (opts) =>
        opts = defaults opts,
            account_id       : required
            collabs_as_names : true       # replace all account_id's of project collabs with their user names.
            hidden           : false      # if true, get *ONLY* hidden projects; if false, don't include hidden projects
            cb               : required

        ids                = undefined
        projects           = undefined
        hidden_project_ids = undefined
        async.series([
            (cb) =>
                async.parallel([
                    (cb) =>
                        @get_project_ids_with_user
                            account_id : opts.account_id
                            cb         : (err, r) =>
                                ids = r
                                cb(err)
                    (cb) =>
                        @get_hidden_project_ids
                            account_id : opts.account_id
                            cb         : (err, r) =>
                                hidden_project_ids = r
                                cb(err)
                ], cb)

            (cb) =>
                if opts.hidden
                    ids = (x for x in ids when hidden_project_ids[x])
                else
                    ids = (x for x in ids when not hidden_project_ids[x])
                @get_projects_with_ids
                    ids : ids
                    cb  : (err, _projects) =>
                        projects = _projects
                        cb(err)

            (cb) =>
                if not opts.collabs_as_names
                    cb(); return
                account_ids = []
                for p in projects
                    for group in PROJECT_GROUPS
                        if p[group]?
                            for id in p[group]
                                account_ids.push(id)
                @account_ids_to_usernames
                    account_ids : account_ids
                    cb          : (err, usernames) =>
                        if err
                            cb(err); return
                        for p in projects
                            p.hidden = opts.hidden
                            for group in PROJECT_GROUPS
                                if p[group]?
                                    p[group] = ({first_name:usernames[id].first_name, last_name:usernames[id].last_name, account_id:id} for id in p[group] when usernames[id]?)
                        cb()
        ], (err) =>
                opts.cb(err, projects)
        )

    get_projects_with_ids: (opts) ->
        opts = defaults opts,
            ids : required   # an array of id's
            cb  : required

        if opts.ids.length == 0  # easy special case -- don't bother to query db!
            opts.cb(false, [])
            return

        @select
            table     : 'projects'
            columns   : PROJECT_COLUMNS
            objectify : true
            where     : { project_id:{'in':opts.ids} }
            cb        : (error, results) ->
                if error
                    opts.cb(error)
                else
                    for r in results
                        # fill in a default name for the project -- used in the URL
                        if not r.name and r.title?
                            r.name = misc.make_valid_name(r.title)
                    opts.cb(false, results)

    # cb(err, array of account_id's of accounts in non-invited-only groups)
    get_account_ids_using_project: (opts) ->
        opts = defaults opts,
            project_id : required
            cb         : required
        @select
            table      : 'projects'
            columns    : (c for c in PROJECT_COLUMNS when c.indexOf('invited') == -1)
            where      : { project_id : opts.project_id }
            cb         : (err, results) =>
                if err
                    opts.cb(err)
                else
                    v = []
                    for r in results
                        v = v.concat(r)
                    opts.cb(false, v)

    # Get array of uuid's all *all* projects in the database
    get_all_project_ids: (opts) =>   # cb(err, [project_id's])
        opts = defaults opts,
            cb      : required
            deleted : false     # by default, only return non-deleted projects
        @select
            table   : 'projects'
            columns : ['project_id', 'deleted']
            cb      : (err, results) =>
                if err
                    opts.cb(err)
                else
                    if not opts.deleted  # can't do this with a query given current data model.
                        ans = (r[0] for r in results when not r[1])
                    else
                        ans = (r[0] for r in results)
                    opts.cb(false, ans)

    update_project_count: (cb) =>
        @count
            table : 'projects'
            cb    : (err, value) =>
                @set_table_counter
                    table : 'projects'
                    value : value
                    cb    : cb

    # If there is a cached version of stats (which has given ttl) return that -- this could have
    # been computed by any of the hubs.  If there is no cached version, compute anew and store
    # in cache for ttl seconds.
    # CONCERN: This could take around 15 seconds, and numerous hubs could all initiate it
    # at once, which is a waste.
    # TODO: This *can* be optimized to be super-fast by getting rid of all counts; to do that,
    # we need a list of all possible servers, say in a file or somewhere.  That's for later.
    get_stats: (opts) ->
        opts = defaults opts,
            ttl : 60  # how long cached version lives (in seconds)
            cb  : required
        stats = {timestamp:moment(new Date()).format('YYYY-MM-DD-HHmmss') }
        cached_answer = undefined
        async.series([
            (cb) =>
                @select
                    table     : 'stats_cache'
                    where     : {dummy:true}
                    objectify : true
                    json      : ['hub_servers']
                    columns   : [ 'timestamp', 'accounts', 'projects', 'active_projects',
                                  'last_day_projects', 'last_week_projects',
                                  'last_month_projects', 'hub_servers']
                    cb        : (err, result) =>
                        if err
                            cb(err)
                        else if result.length == 0 # nothing in cache
                            cb()
                        else
                            # done
                            cached_answer = result[0]
                            # don't do anything else
                            cb(true)
            (cb) =>
                @get_table_counter
                    table : 'accounts'
                    cb    : (err, val) =>
                        stats.accounts = val
                        cb(err)
            (cb) =>
                @get_table_counter
                    table : 'projects'
                    cb    : (err, val) =>
                        stats.projects = val
                        cb(err)
            (cb) =>
                @count
                    table : 'recently_modified_projects'
                    where : {ttl : 'short'}
                    cb    : (err, val) =>
                        stats.active_projects = val
                        cb(err)
            (cb) =>
                @count
                    table : 'recently_modified_projects'
                    where : {ttl : 'day'}
                    cb    : (err, val) =>
                        stats.last_day_projects = val
                        cb(err)
            (cb) =>
                @count
                    table : 'recently_modified_projects'
                    where : {ttl : 'week'}
                    cb    : (err, val) =>
                        stats.last_week_projects = val
                        cb(err)
            (cb) =>
                cb(); return
                ###
                # TODO: this has got too big and is now too
                # slow, causing timeouts.
                @count
                    table : 'recently_modified_projects'
                    where : {ttl : 'month'}
                    cb    : (err, val) =>
                        stats.last_month_projects = val
                        cb(err)
                ###
            (cb) =>
                @select
                    table     : 'hub_servers'
                    columns   : ['host', 'port', 'clients']
                    objectify : true
                    where     : {dummy: true}
                    cb    : (err, val) =>
                        stats.hub_servers = val
                        cb(err)
            (cb) =>
                @update
                    table : 'stats'
                    set   : stats
                    json  : ['hub_servers']
                    where : {time:now()}
                    cb    : cb
            (cb) =>
                @update
                    table : 'stats_cache'
                    set   : stats
                    where : {dummy : true}
                    json  : ['hub_servers']
                    ttl   : opts.ttl
                    cb    : cb
            (cb) =>
                # store result in a cache
                cb()
        ], (err) =>
            if cached_answer?
                opts.cb(false, cached_answer)
            else
                opts.cb(err, stats)
        )

    #####################################
    # Storage server
    #####################################

    # Get ssh address to connect to a given storage server in various ways.
    storage_server_ssh: (opts) =>
        opts = defaults opts,
            server_id : required
            cb        : required
        @select_one
            table       : 'storage_servers'
            consistency : 1
            where       :
                dummy     : true
                server_id : opts.server_id
            columns     : ['ssh']
            cb          : (err, r) =>
                if err
                    opts.cb(err)
                else
                    opts.cb(undefined, r[0])

    #####################################
    # Tasks
    #####################################
    create_task_list: (opts) =>
        opts = defaults opts,
            owners      : required
            cb          : required
        task_list_id = uuid.v4()

        q = ('?' for i in [0...opts.owners.length]).join(',')
        query = "UPDATE task_lists SET owners={#{q}}, last_edited=? WHERE task_list_id=?"
        args = (x for x in opts.owners)
        args.push(now())
        args.push(task_list_id)
        @cql(query, args, (err) => opts.cb(err, task_list_id))

    create_task: (opts) =>
        opts = defaults opts,
            task_list_id : required
            title        : required
            position     : 0
            cb           : required

        task_id = uuid.v4()
        last_edited = now()
        async.parallel([
            (cb) =>
                @update
                    table : 'tasks'
                    where :
                        task_list_id : opts.task_list_id
                        task_id      : task_id
                    set   :
                        title       : opts.title
                        position    : opts.position
                        done        : false   # tasks start out not done
                        last_edited : last_edited
                    cb    : cb
            (cb) =>
                # record that something about the task list itself changed
                @update
                    table : 'task_lists'
                    where : {task_list_id : opts.task_list_id}
                    set   : {last_edited  : last_edited}
                    cb    : cb
        ], (err) =>
            if err
                opts.cb(err)
            else
                opts.cb(undefined, task_id)
        )

    get_task_list : (opts) =>
        opts = defaults opts,
            task_list_id    : required
            include_deleted : false
            columns         : undefined
            cb              : required

        if opts.columns?
            columns = opts.columns
        else
            columns = ['task_id', 'position', 'last_edited', 'done', 'title', 'data', 'deleted', 'sub_task_list_id']

        t = {}
        async.parallel([
            (cb) =>
                @select
                    table     : 'tasks'
                    where     : {task_list_id : opts.task_list_id}
                    columns   : columns
                    objectify : true
                    cb        : (err, resp) =>
                        if err
                            cb(err)
                        else
                            if not opts.include_deleted and 'deleted' in columns
                                resp = (x for x in resp when not x.deleted)
                            for x in resp
                                if x.data?
                                    for k, v of x.data
                                        x.data[k] = from_json(v)
                            t.tasks = resp
                            cb()
            (cb) =>
                @select_one
                    table   : 'task_lists'
                    where   : {task_list_id : opts.task_list_id}
                    columns : ['data']
                    cb      : (err, resp) =>
                        if err
                            cb(err)
                        else
                            data = resp[0]
                            if data?
                                for k, v of data
                                    t[k] = from_json(v)
                            cb()
        ], (err) =>
            if err
                opts.cb(err)
            else
                opts.cb(undefined, t)
        )

    get_task_list_last_edited : (opts) =>
        opts = defaults opts,
            task_list_id    : required
            cb              : required
        @select_one
            table   : 'task_lists'
            columns : ['last_edited']
            cb      : (err, r) =>
                if err
                    opts.cb(err)
                else
                    opts.cb(undefined, r[0])

    set_project_task_list: (opts) =>
        opts = defaults opts,
            task_list_id    : required
            project_id      : required
            cb              : required
        @update
            table : 'projects'
            set   : {task_list_id : opts.task_list_id, last_edited : now()}
            where : {project_id : opts.project_id}
            cb    : opts.cb


    edit_task_list : (opts) =>
        opts = defaults opts,
            task_list_id : required
            data         : undefined
            deleted      : undefined
            cb           : required
        #dbg = (m) -> winston.debug("edit_task_list: #{m}")
        if opts.deleted
            #dbg("delete the entire task list and all the tasks in it")
            tasks = undefined
            already_deleted = false
            async.series([
                (cb) =>
                    #dbg("is task list already deleted?  if so, do nothing to avoid potential recursion due to nested sub-tasks.")
                    @select_one
                        table   : 'task_lists'
                        columns : ['deleted']
                        where   : {task_list_id : opts.task_list_id}
                        cb      : (err, resp) =>
                            if err
                                cb(err)
                            else
                                already_deleted = resp[0]
                                cb(already_deleted)
                (cb) =>
                    #dbg("get list of tasks")
                    @get_task_list
                        task_list_id    : opts.task_list_id
                        columns         : ['task_id', 'deleted']
                        include_deleted : false
                        cb              : (err, _tasks) =>
                            if err
                                cb(err)
                            else
                                tasks = (x.task_id for x in _tasks)
                                cb()
                (cb) =>
                    #dbg("delete them all")
                    f = (task_id, cb) =>
                        @edit_task
                            task_list_id : opts.task_list_id
                            task_id      : task_id
                            deleted      : true
                            cb           : cb
                    async.map(tasks, f, (err) => cb(err))
                (cb) =>
                    #dbg("delete the task list itself")
                    @update
                        table : 'task_lists'
                        set   : {'deleted': true, 'last_edited':now()}
                        where : {task_list_id : opts.task_list_id}
                        cb    : cb
            ], (err) =>
                if already_deleted
                    opts.cb()
                else
                    opts.cb(err)
            )
        else
            #dbg("other case -- just edit data properties of the task_list")
            if not opts.data?
                opts.cb(); return
            f = (key, cb) =>
                if key == 'tasks'
                    cb("you may not use 'tasks' as a custom task_lists field")
                    return
                query = "UPDATE task_lists SET data[?]=?, last_edited=? WHERE task_list_id=?"
                if opts.data[key] != null
                    val = to_json(opts.data[key])
                else
                    val = undefined
                @cql(query, [key, val, now(), opts.task_list_id], (err) => cb(err))
            async.map(misc.keys(opts.data), f, (err) => opts.cb(err))

    edit_task : (opts) =>
        opts = defaults opts,
            task_list_id : required
            task_id      : required
            title        : undefined
            position     : undefined
            done         : undefined
            data         : undefined
            deleted      : undefined
            sub_task_list_id : undefined
            cb           : undefined

        winston.debug("cass edit_task: opts=#{misc.to_json(opts)}")

        where =
            task_list_id : opts.task_list_id
            task_id      : opts.task_id

        last_edited = now()

        async.series([
            (cb) =>
                if not opts.deleted
                    cb(); return
                # deleting -- so delete the subtask list if there is one
                @select_one
                    table   : 'tasks'
                    columns : ['sub_task_list_id']
                    where   : where
                    cb      : (err, r) =>
                        if err
                            cb(err)
                        else
                            if r[0]
                                @edit_task_list
                                    task_list_id : r[0]
                                    deleted      : true
                                    cb           : cb
                            else
                                cb()
            (cb) =>
                # set the easy properties
                set = {last_edited: now()}
                if opts.title?
                    set.title = opts.title
                if opts.position?
                    set.position = opts.position
                if opts.done?
                    set.done = opts.done
                if opts.deleted?
                    set.deleted = opts.deleted
                set.last_edited = last_edited
                @update
                    table : 'tasks'
                    where : where
                    set   : set
                    cb    : cb
            (cb) =>
                # set any data properties
                f = (key, cb) =>
                    query = "UPDATE tasks SET data[?]=? WHERE task_list_id=? AND task_id=?"
                    if opts.data[key] != null
                        val = to_json(opts.data[key])
                    else
                        val = undefined
                    @cql(query, [key, val, opts.task_list_id, opts.task_id], (err) => cb(err))
                async.map(misc.keys(opts.data), f, (err) => cb(err))
            (cb) =>
                # record that something about the task list itself changed
                @update
                    table : 'task_lists'
                    where : {task_list_id : opts.task_list_id}
                    set   : {last_edited  : last_edited}
                    cb    : cb
        ], (err) => opts.cb?(err))



    # Remove all deleted tasks and task lists from the database, so long as their
    # last edit time is at least min_age_s seconds ago.
    purge_deleted_tasks : (opts) =>
        opts = defaults opts,
            min_age_s : 3600*24*30  # one month  -- min age in seconds
            cb        : undefined
        results = undefined
        async.series([
            (cb) =>
                # TODO: implement paging through list of tasks -- this will only work for a few months, then die.
                console.log("dumping tasks table...")
                @select
                    table   : 'tasks'
                    columns : ['deleted', 'task_list_id', 'task_id', 'last_edited']
                    cb      : (err, r) =>
                        if err
                            cb(err)
                        else
                            console.log("got #{r.length} tasks")
                            results = r
                            cb()
            (cb) =>
                n = (new Date()) - 0
                x = ([r[1],r[2]] for r in results when r[0] and (n - r[3]) >= opts.min_age_s)
                console.log("deleting #{x.length} deleted tasks")
                f = (z, cb) =>
                    console.log("deleting #{misc.to_json(z)}")
                    @delete
                        table : 'tasks'
                        where : {task_list_id:z[0], task_id:z[1]}
                        cb    : cb
                async.mapLimit(x, 10, f, (err) => cb(err))
            (cb) =>
                # TODO: implement paging through list of tasks -- this will only work for a few months, then die.
                console.log("dumping task_lists table...")
                @select
                    table   : 'task_lists'
                    columns : ['deleted', 'task_list_id', 'last_edited']
                    cb      : (err, r) =>
                        if err
                            cb(err)
                        else
                            console.log("got #{r.length} task_lists")
                            results = r
                            cb()
            (cb) =>
                n = (new Date()) - 0
                console.log("results=", results)
                x = (r[1] for r in results when r[0] and (n - r[2]) >= opts.min_age_s)
                console.log("deleting #{x.length} deleted task_lists")
                f = (z, cb) =>
                    console.log("deleting task_list #{z}")
                    @delete
                        table : 'task_lists'
                        where : {task_list_id:z}
                        cb    : cb
                async.mapLimit(x, 10, f, (err) => cb(err))
        ], (err) => opts.cb?(err))


############################################################################
# Chunked storage for each project (or user, or whatever is indexed by a uuid).
# Store arbitrarily large blob data associated to each project here.
# This uses the storage and storage_blob tables.
############################################################################

exports.storage_db = (opts) ->
    opts = defaults opts,
        hosts : ['10.1.3.1', '10.1.10.1']
        consistency : 1
        cb    : required

    fs.readFile "#{process.cwd()}/data/secrets/storage/storage_server", (err, password) ->
        if err
            opts.cb(err)
        else
            new exports.Salvus
                hosts    : opts.hosts
                keyspace : 'storage'
                username : 'storage_server'
                consistency : opts.consistency
                password : password.toString().trim()
                cb       : opts.cb

exports.storage_sync = (opts) ->
    opts = defaults opts,
        project_ids : required
        streams     : '/storage/streams'
        limit       : 3           # max to sync at once
        verbose     : true
        cb          : undefined
    if opts.verbose
        dbg = (m) -> winston.debug("storage_sync: #{m}")
    else
        dbg = (m) ->
    db = undefined
    errors = {}
    async.series([
        (cb) ->
            dbg("get database connection")
            exports.storage_db
                hosts : ['10.1.3.1', '10.1.10.1']
                cb : (err, x) ->
                    db = x
                    cb(err)
        (cb) ->
            i = 0
            n = opts.project_ids.length
            f = (project_id, c) ->
                t = misc.walltime()
                i += 1
                j = i
                dbg("syncing #{j}/#{n}: #{project_id}")
                cs = db.chunked_storage(id:project_id)
                cs.verbose = opts.verbose
                cs.sync
                    path : opts.streams + '/' + project_id
                    cb   : (err) ->
                        dbg("********************************************************************")
                        dbg("** FINISHED (#{j}/#{n}) syncing #{project_id} in #{misc.walltime(t)} seconds **")
                        dbg("********************************************************************")
                        if err
                            dbg("syncing #{project_id} resulted in error: #{err}")
                            errors[project_id] = err
            async.mapLimit(opts.project_ids, opts.limit, f, cb)
    ], (err) ->
        if misc.len(errors) > 0
            dbg("ERRORS -- #{misc.to_json(errors)}")
            opts.cb?(errors)
            return
        if err
            dbg("ERROR -- #{err}")
        opts.cb?(err)
    )


exports.storage_migrate = (opts) ->
    opts = defaults opts,
        start   : required  # integer
        stop    : required  # integer
        streams : required  # path to streams
        limit   : 5         # number to sync to DB at once.
        verbose : false
        timeout : 0         # wait this many seconds after each sync to give database time to "breath"
        db      : undefined
        cb      : undefined

    dbg = (m) -> winston.debug("storage_migrate: #{m}")
    db = opts.db
    files = undefined
    errors = {}
    async.series([
        (cb) ->
            if db?
                cb(); return
            dbg("getting db")
            exports.storage_db
                hosts : ("10.1.#{i}.1" for i in [1,2,3,4,5,7,10,11,12,13,14,15,16,17,18,19,20,21])
                cb : (err, x) ->
                    db = x
                    cb(err)
        (cb) ->
            dbg("reading dirctory")
            fs.readdir opts.streams, (err, x) ->
                if err
                    cb(err)
                else
                    x.sort()
                    dbg("contains #{x.length} files")
                    files = x.slice(opts.start, opts.stop)
                    cb()
        (cb) ->
            i = 0
            f = (project_id, c) ->
                t = misc.walltime()
                i += 1
                j = i
                dbg("syncing #{j}/#{files.length}: #{project_id}")
                cs = db.chunked_storage(id:project_id)
                cs.verbose = opts.verbose
                cs.sync_put
                    path : opts.streams + '/' + project_id
                    cb   : (err) ->
                        dbg("********************************************************************")
                        dbg("** FINISHED (#{j}/#{files.length}) syncing #{project_id} in #{misc.walltime(t)} seconds **")
                        dbg("********************************************************************")
                        if err
                            dbg("syncing #{project_id} resulted in error: #{err}")
                            errors[project_id] = err
                        setTimeout(c, opts.timeout*1000)  # let it break
            async.mapLimit(files, opts.limit, f, cb)
    ], (err) ->
        if err
            opts.cb?(err)
        else
            if misc.len(errors) > 0
                opts.cb?(errors)
            else
                opts.cb?()
    )



class ChunkedStorage

    constructor: (opts) ->
        opts = defaults opts,
            db      : required     # db = a database connection
            id      : required     # id = a uuid
            verbose : true   # verbose = if true, log a lot about what happens.
            limit   : 3
        @db = opts.db
        @id = opts.id
        @verbose = opts.verbose
        @limit = opts.limit
        @dbg("constructor", undefined, 'create')

    dbg: (f, args, m) =>
        if @verbose
            winston.debug("ChunkedStorage(#{@id}).#{f}(#{misc.to_json(args)}): #{m}")


    active_files: (opts) =>
        opts = defaults opts,
            cb    : required
        dbg = (m) => @dbg('active_files', '', m)
        results = undefined
        dbg("querying the storage_writing table...")
        @db.select
            table     : 'storage_writing'
            columns   : ['timestamp', 'name', 'size']
            where     : {dummy:true}
            objectify : true
            cb        : (err, results) =>
                if err
                    opts.cb(err)
                else
                    for r in results
                        r.timestamp = new Date(r.timestamp)
                    opts.cb(undefined, results)

    # Delete any chunks that aren't referenced by some object successfully created --
    # this is not restricted to this particular project but all projects.
    # x={};require('cassandra').storage_db(hosts:['10.1.3.1'],consistency:2, cb:(e,d)->x.d=d;x.c=x.d.chunked_storage(id:'dcce4891-2132-436c-9274-8d659e91bde5'))
    #
    delete_lost_chunks: (opts) =>
        opts = defaults opts,
            age_s : 120*60  # 2 hours -- delete all chunks associated to any records in storage_active that are at least this old
            cb    : undefined
        dbg = (m) => @dbg('delete_lost_chunks', '', m)

        opts.cb("TODO: do not use this yet -- it should be changed to verify that lost data *really* is lost!  Since the way things are done, the data could be perfectly written and the only problem is deleting the storage writing record.")

        results = undefined
        tm      = exports.seconds_ago(opts.age_s)
        async.series([
            (cb) =>
                dbg("querying the storage_writing table...")
                @db.select
                    table     : 'storage_writing'
                    columns   : ['timestamp', 'id', 'name', 'chunk_ids']
                    where     : {dummy:true}
                    objectify : true
                    cb        : (err, _results) =>
                        if err
                            cb(err)
                        else
                            results = _results
                            dbg("get #{results.length} files")
                            cb()
            (cb) =>
                f = (r, c) =>
                    if new Date(r.timestamp) > tm
                        dbg("skipping: #{r.id}/#{r.name} -- too new")
                        c(); return
                    dbg("lost file: #{r.id}/#{r.name} -- #{r.chunk_ids.length} chunks")
                    @db.delete
                        table  : 'storage_chunks'
                        where  : {chunk_id:{'in':r.chunk_ids}}
                        cb     : (err) =>
                            if not err
                                dbg("deleting chunks for #{r.id}/#{r.name}; now removing from storage_writing table")
                                @db.delete
                                    table : 'storage_writing'
                                    where : {timestamp:r.timestamp, id:r.id, name:r.name, dummy:true}
                                    cb    : c
                            else
                                dbg("error deleting chunks for file #{r.id}/#{r.name}")
                                c(err)
                async.map(results, f, cb)
        ], (err) => opts.cb?(err))

    # list of objects in chunked storage for this project
    ls: (opts) =>
        opts = defaults opts,
            cb  : required # cb(err, [array of {name:, size:} objects])
        @db.select
            table     : 'storage'
            where     : {id:@id}
            columns   : ['name', 'size']
            objectify : true
            cb        : (err, results) =>
                if err
                    opts.cb(err)
                else
                    opts.cb(undefined, ({name:r.name, size:parseInt(r.size)} for r in results))

    # total usage of all objects
    size: (opts) =>
        opts = defaults opts,
            cb  : required # cb(err, [array of {name:, size:} objects])
        @ls
            cb : (err, v) =>
                if err
                    opts.cb(err)
                else
                    size = 0
                    for f in v
                        size += f.size
                    opts.cb(undefined, size)

    # write file/blob to the cassandra database
    put: (opts) =>
        opts = defaults opts,
            name          : undefined  # defaults to equal filename if given; if filename not given, name *must* be given
            blob          : undefined  # Buffer  # EXACTLY ONE of blob or path must be defined
            filename      : undefined  # filename  -- instead read blob directly from file, which will work even if file is HUGE
            chunk_size_mb : 4          # 4MB
            limit         : undefined  # max number of chunks to save at once
            cb            : undefined

        if not opts.limit?
            opts.limit = @limit

        if not opts.blob? and not opts.filename?
            opts.cb?("either a blob or filename must be given")
            return

        if opts.blob?
            if opts.filename?
                opts.cb?("exactly one of blob or filename must be given but NOT both")
            else
                if typeof(opts.blob) == "string"
                    opts.blob = new Buffer(opts.blob)

        if not opts.name?
            if not opts.filename?
                opts.cb?("if name isn't given, then filename must be given")
            else
                opts.name = opts.filename

        dbg = (m) => @dbg('put', opts.name, m)
        dbg()
        total_time = misc.walltime()

        if opts.name and opts.name[opts.name.length-1] == '/'
            dbg("it's a directory (not file)")
            query = "UPDATE storage SET chunk_ids=[], size=?, chunk_size=? WHERE id=? AND name=?"
            dbg(query)
            @db.cql(query, ["0", chunk_size, @id, opts.name], (err) => opts.cb?(err))
            return


        chunk_size = opts.chunk_size_mb * 1000000
        size       = undefined
        fd         = undefined
        num_chunks = undefined
        chunk_ids  = undefined
        chunk_ids_string = undefined
        timestamp  = undefined

        async.series([
            (cb) =>
                dbg("get size of blob or filename")
                if opts.blob?
                    size = opts.blob.length
                    cb()
                else
                    fs.stat opts.filename, (err, stats) =>
                        if err
                            cb(err)
                        else
                            size = stats.size
                            # also, get the file descriptor, so we can read randomly chunks of the file.
                            # Reading the whole file at once could easily run out of address space or RAM!
                            fs.open opts.filename, 'r', (err, _fd) =>
                                fd = _fd
                                cb(err)

            (cb) =>
                dbg("determine number of chunks and chunk ids and save in active table")
                num_chunks = Math.ceil(size / chunk_size)
                # do not use Sha1 -- even though that might be nice in theory and for some sort of (highly unlikely!) dedup,
                # in practice it would require reference counting and making the code much more complicated and error prone.
                chunk_ids = (uuid.v4() for i in [0...num_chunks])
                chunk_ids_string = "[#{chunk_ids.join(',')}]"
                timestamp = now()
                query = "UPDATE storage_writing SET chunk_ids=#{chunk_ids_string}, size=?, chunk_size=? WHERE dummy=? AND id=? AND name=? AND timestamp=?"
                @db.cql(query, [""+size, chunk_size, true, @id, opts.name, timestamp], cb)

            (cb) =>

                dbg("saving the chunks")
                get_chunk = (start, end, c) =>
                    if opts.blob?
                        c(undefined, opts.blob.slice(start, end))
                    else
                        chunk = new Buffer(end-start)
                        fs.read fd, chunk, 0, chunk.length, start, (err) =>
                            c(err, chunk)

                num_saved = 0
                f = (i, c) =>
                    t = misc.walltime()
                    chunk_id = chunk_ids[i]
                    dbg("reading and store chunk #{i}/#{num_chunks-1}: #{chunk_id}")
                    start = i*chunk_size
                    end   = Math.min(size, (i+1)*chunk_size)  # really ends at pos one before this.
                    get_chunk start, end, (err, chunk) =>
                        if err
                            c(err)
                        else
                            query = "UPDATE storage_chunks SET chunk=?, size=? WHERE chunk_id=?"
                            @db.cql query, [chunk, chunk.length, chunk_id], 1, (err) =>
                                num_saved += 1
                                dbg("saved chunk #{i} -- now #{num_saved} of #{num_chunks} done.  (#{misc.walltime(t)} s)")
                                c(err)

                async.mapLimit [0...num_chunks], opts.limit, f, (err) =>
                    if err
                        dbg("something went wrong writing chunks (#{misc.to_json(err)}): delete any chunks we just wrote")
                        g = (id, c) =>
                            @db.delete
                                table : 'storage_chunks'
                                where : {chunk_id:id}
                                cb    : (ignored) => c()
                        async.map chunk_ids, g, (ignored) => cb(err)
                    else
                        cb()

            (cb) =>
                dbg("now all new chunks are successfully saved so delete any previous chunks")
                @delete
                    name       : opts.name
                    limit      : opts.limit
                    cb         : (err) =>
                        if err
                            # ignoring this at worse leaks storage at this point.
                            dbg("ignoring error deleting previous chunks: #{err}")
                        dbg("writing index to new chunks: #{chunk_ids_string}")
                        query = "UPDATE storage SET chunk_ids=#{chunk_ids_string}, size=?, chunk_size=? WHERE id=? AND name=?"
                        dbg(query)
                        @db.cql(query, [""+size, chunk_size, @id, opts.name], cb)
            (cb) =>
                dbg("remove storage_writing active record")
                @db.delete
                    table : 'storage_writing'
                    where : {id:@id, name:opts.name, timestamp:timestamp, dummy:true}
                    cb    : cb
        ], (err) =>
            if fd?
                fs.close(fd)
            dbg("total time: #{misc.walltime(total_time)}")
            opts.cb?(err)
        )

    # get file/blob from the cassandra database (to memory or a local file)
    get: (opts) =>
        opts = defaults opts,
            name       : undefined  # if not given, defaults to filename
            filename   : undefined  # if given, write result to the file with this name instead of returning a new Buffer, which is CRITICAL if object is large!
            limit      : undefined  # max number of chunks to read at once
            cb         : required

        total_time = misc.walltime()
        dbg = (m) => @dbg('get', {name:opts.name,filename:opts.filename}, m)
        dbg()

        if not opts.limit?
            opts.limit = @limit

        if not opts.name?
            if not opts.filename?
                opts.cb("name or filename must be given")
                return
            opts.name = opts.filename

        dbg = (m) => @dbg('get', opts.name, m)
        dbg()

        if opts.filename? and opts.filename[opts.filename.length-1] == '/'
            dbg("directory (not file)")
            if opts.filename[0] != '/'
                path = process.cwd()+'/'+opts.filename
            else
                path = opts.filename
            path = path.slice(0,path.length-1)  # get rid of trailing /
            fs.exists path, (exists) =>
                if exists
                    opts.cb()
                else
                    misc_node.ensure_containing_directory_exists path, (err) =>
                        if err
                            opts.cb(err)
                        else
                            fs.mkdir path, 0o700, (err) =>
                                if err
                                    if err.code == 'EEXIST'
                                        opts.cb()
                                    else
                                        opts.cb(err)
                                else
                                    opts.cb()

            return



        chunk_ids = undefined
        chunks = {}
        chunk_size = undefined
        fd = undefined

        writing_chunks = false
        write_chunks_to_file = (cb) =>
            # write all chunks in chunks to the file
            if writing_chunks
                f = () =>
                    write_chunks_to_file(cb)
                setTimeout(f, 250)  # check again soon
            else
                if misc.len(chunks) == 0
                    cb(); return # done
                # Write everything
                writing_chunks = true
                f = (chunk, c) =>
                    dbg("writing chunk starting at #{chunk.start} to #{opts.filename}")
                    fs.write fd, chunk.chunk, 0, chunk.chunk.length, chunk.start, (err) =>
                        delete chunks[chunk.chunk_id]
                        c(err)
                v = (chunk for chunk_id, chunk of chunks)
                async.mapSeries v, f, (err) =>
                    writing_chunks = false
                    cb(err)

        tmp_filename = undefined
        async.series([
            (cb) =>
                if opts.filename?
                    tmp_filename = opts.filename+'.tmp'
                    dbg("open output file #{tmp_filename}")
                    p = opts.filename
                    if p[0] != '/'
                        p = process.cwd()+'/'+p
                    misc_node.ensure_containing_directory_exists p, (err) =>
                        if err
                            cb(err)
                        else
                            fs.open tmp_filename, 'w', (err, _fd) =>
                                fd = _fd
                                cb(err)
                else
                    cb()
            (cb) =>
                dbg("get chunk ids")
                @db.select_one
                    table     : 'storage'
                    where     : {id:@id, name:opts.name}
                    columns   : ['chunk_ids', 'chunk_size']
                    objectify : true
                    cb        : (err, result) =>
                        if err
                            cb(err)
                        else
                            chunk_ids  = result.chunk_ids
                            chunk_size = result.chunk_size
                            dbg("chunk ids=#{misc.to_json(chunk_ids)}")
                            cb()
            (cb) =>
                if not chunk_ids?  # 0-length file
                    cb(); return
                dbg("get chunks")
                consistency = {}
                num_chunks = 0
                f = (i, c) =>
                    t = misc.walltime()

                    # Keep increasing consistency until it works.
                    if not consistency[i]?
                        consistency[i] = cql.types.consistencies.one
                    else
                        consistency[i] = higher_consistency(consistency[i])
                        dbg("increasing read consistency for chunk #{i} to #{consistency[i]}")

                    @db.select_one
                        table       : 'storage_chunks'
                        where       : {chunk_id:chunk_ids[i]}
                        columns     : ['chunk']
                        objectify   : false
                        consistency : consistency[i]
                        cb          : (err, result) =>
                            if err
                                dbg("failed to read chunk #{i}/#{chunk_ids.length-1} from DB in #{misc.walltime(t)} s -- #{err}; may retry with higher consistency")
                                c(err)
                            else
                                num_chunks += 1
                                dbg("got chunk #{i}:  #{num_chunks} of #{chunk_ids.length} chunks (time: #{misc.walltime(t)}s)")
                                chunk = result[0]
                                chunks[chunk_ids[i]] = {chunk:chunk, start:i*chunk_size, chunk_id:chunk_ids[i]}
                                if opts.filename?
                                    if misc.len(chunks) >= opts.limit
                                        # attempt to write the chunks we have so far to the file -- one at a time before returning (which will slow things down)
                                        write_chunks_to_file(c)
                                    else
                                        c()
                                else
                                    c()
                g = (i, c) =>
                    h = (c) =>
                        f(i,c)
                    misc.retry_until_success
                        f         : h
                        max_tries : CONSISTENCIES.length + 1
                        max_delay : 3000
                        cb        : c
                async.mapLimit([0...chunk_ids.length], opts.limit, g, cb)
            (cb) =>
                if opts.filename?
                    dbg("write any remaining chunks to file")
                    write_chunks_to_file(cb)
                else
                    cb()
        ], (err) =>
            dbg("total time: #{misc.walltime(total_time)}")
            if fd?
                fs.close(fd)
            if err
                dbg("error reading file from database -- #{err}; removing #{tmp_filename}}")
                fs.unlink tmp_filename, (ignore) =>
                    opts.cb(err)
            else
                if not opts.filename?
                    dbg("assembling in memory buffers together to make blob")
                    blob = Buffer.concat( (chunks[chunk_id].chunk for chunk_id in chunk_ids) )
                    opts.cb(undefined, blob)
                else
                    dbg("tmp file wrote -- moving to real file: #{tmp_filename} --> #{opts.filename}")
                    fs.rename(tmp_filename, opts.filename, opts.cb)
        )

    # DANGEROUS!! -- delete *every single file* in this storage object
    # USE WITH CAUTION.
    delete_everything: (opts) =>
        opts = defaults opts,
            limit      : 3             # number to files delete at once
            cb         : undefined
        f = (name, cb) =>
            @delete
                name : name
                cb   : cb
        @ls
            cb: (err, files) =>
                async.mapLimit((file.name for file in files), opts.limit, f, (err) => opts.cb?(err))

    delete: (opts) =>
        opts = defaults opts,
            name       : required
            limit      : undefined           # number of chunks to delete at once
            cb         : undefined
        if not opts.limit?
            opts.limit = @limit
        dbg = (m) => @dbg('delete', opts.name, m)
        chunk_ids = undefined
        async.series([
            (cb) =>
                dbg("get chunk ids")
                @db.select
                    table     : 'storage'
                    where     : {id : @id, name : opts.name}
                    columns   : ['chunk_ids']
                    objectify : false
                    cb        : (err, result) =>
                        if err
                            cb(err)
                        else
                            if result.length > 0
                                chunk_ids = result[0][0]
                                if not chunk_ids?
                                    chunk_ids = []
                                dbg("chunk ids=#{misc.to_json(chunk_ids)}")
                            else
                                dbg("nothing there")
                            cb()
            (cb) =>
                if not chunk_ids?
                    cb(); return
                dbg("delete chunks")
                fail = false
                f = (i, c) =>
                    t = misc.walltime()
                    @db.delete
                        table : 'storage_chunks'
                        where : {chunk_id:chunk_ids[i]}
                        cb    : (err) =>
                            if err
                                fail = err
                                # nonfatal -- so at least all the other chunks get deleted, and next time this one does.
                                c()
                            else
                                dbg("deleted chunk #{i}/#{chunk_ids.length-1} in #{misc.walltime(t)} s")
                                c()
                async.mapLimit([0...chunk_ids.length], opts.limit, f, (err) -> cb(fail))
            (cb) =>
                if not chunk_ids?
                    cb(); return
                dbg("delete index")
                @db.delete
                    table : 'storage'
                    where : {id : @id, name : opts.name}
                    cb    : cb
        ], (err) => opts.cb?(err))

    # Sync back and forth between a path and the database:
    #
    # Files with the same name and size are considered equal (for our application
    # this is fine).
    #
    # Directories are files whose name ends in a slash.

    sync_diff: (opts) =>
        opts = defaults opts,
            path : required,
            cb   : required     # cb(err, {local_only:local_only_files, db_only:db_only_files})

        dbg = (m) => @dbg('sync_diff', opts.path, m)
        db_files    = {}  # map filename:size with keys the db files
        local_files = {}  # map filename:size with keys the local files
        async.series([
            (cb) =>
                dbg("files in database")
                @ls
                    cb : (err, x) =>
                        if err
                            cb(err)
                        else
                            for f in x
                                db_files[f.name] = f.size
                            cb()
            (cb) =>
                dbg("ensure path exists")
                fs.exists opts.path, (exists) =>
                    if not exists
                        fs.mkdir(opts.path, 0o700, cb)
                    else
                        cb()
            (cb) =>
                dbg("get files in path")
                misc_node.execute_code
                    command     : 'find'
                    args        : [opts.path, '-printf', '%y %s %P\n']  # type size_bytes filename
                    timeout     : 360
                    err_on_exit : true
                    path        : process.cwd()
                    verbose     : @verbose
                    cb          : (err, output) ->
                        if err
                            cb(err)
                        else
                            for x in output.stdout.split('\n')
                                v = misc.split(x)
                                if v.length == 3
                                    if v[0] == 'd' or v[0] == 'f'  # only files and directories
                                        name = v[2]
                                        if v[0] == 'd'
                                            name += '/'
                                        local_files[name] = parseInt(v[1])
                            cb()
        ], (err) =>
            if err
                opts.cb(err)
            else
                local_only_files = (name for name, size of local_files when db_files[name] != size)
                db_only_files    = (name for name, size of db_files when local_files[name] != size)
                opts.cb(undefined, {local_only:local_only_files, db_only:db_only_files})
        )


    # Copy any files in path not in database *to* the database.
    sync_put: (opts) =>
        opts = defaults opts,
            path   : required
            delete : false          # if true, deletes anything in the database not in the path
            cb     : undefined
        dbg = (m) => @dbg('sync_put', opts.path, m)
        diff = undefined
        copied = {}
        async.series([
            (cb) =>
                @sync_diff
                    path : opts.path
                    cb   : (err, x) =>
                        diff = x
                        cb(err)
            (cb) =>
                if diff.local_only.length == 0
                    cb(); return
                dbg("copy all new local files to database")
                f = (name, c) =>
                    copied[name] = true
                    @put
                        name     : name
                        filename : opts.path + '/'+name
                        cb       : c
                async.mapLimit(diff.local_only, 3, f, (err,r)=>cb(err))  # up to 3 files at once

            (cb) =>
                if opts.delete
                    to_delete = (name for name in diff.db_only when not copied[name])
                    if to_delete.length == 0
                        cb(); return
                    dbg("delete #{to_delete.length} files in database not in local path")
                    f = (name, c) =>
                        @delete
                            name : name
                            cb   : c
                    async.mapLimit(to_delete, 10, f, (err,r)=>cb(err))   # less restrictive limit -- deleting is easies
                else
                    cb()
        ], (err) => opts.cb?(err))


    # Copy any files not in path *from* the database to the local directory.
    sync_get: (opts) =>
        opts = defaults opts,
            path   : required
            delete : false       # if true, deletes local files not in database, after doing the copy successfully.
            cb     : undefined
        dbg = (m) => @dbg('sync_get', opts.path, m)
        diff = undefined
        copied = {}
        async.series([
            (cb) =>
                @sync_diff
                    path : opts.path
                    cb   : (err, x) =>
                        diff = x
                        cb(err)
            (cb) =>
                if diff.db_only.length == 0
                    cb(); return
                dbg("get all files only (or changed) in db")
                f = (name, c) =>
                    copied[name] = true
                    @get
                        name     : name
                        filename : opts.path + '/' + name
                        cb       : c
                async.mapLimit(diff.db_only, 3, f, cb)  # up to 3 files at once

            (cb) =>
                if opts.delete
                    to_delete = (name for name in diff.local_only when not copied[name])
                    if to_delete.length == 0
                        cb(); return
                    dbg("delete #{to_delete.length} files locally")
                    f = (name, c) =>
                        fs.unlink(opts.path + '/' + name, c)
                    async.mapLimit(to_delete, 10, f, cb)   # no limit -- deleting is easy.
                else
                    cb()
        ], (err) => opts.cb?(err))


    # First copy any files from the database to path, and any from path (not in db) back to the database,
    # so that the same files (the union) are in both.
    sync: (opts) =>
        opts = defaults opts,
            path   : required
            cb     : undefined
        async.series([
            (cb) =>
                @sync_get
                    path   : opts.path
                    delete : false
                    cb     : cb
            (cb) =>
                @sync_put
                    path   : opts.path
                    delete : false
                    cb     : cb
        ], (err) => opts.cb?(err))


quote_if_not_uuid = (s) ->
    if misc.is_valid_uuid_string(s)
        return "#{s}"
    else
        return "'#{s}'"

array_of_strings_to_cql_list = (a) ->
    '(' + (quote_if_not_uuid(x) for x in a).join(',') + ')'

exports.db_test1 = (n, m) ->
    # Store n large strings of length m in the uuid:value store, then delete them.
    # This is to test how the database performs when hit by such load.

    value = ''
    possible = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    for i in [1...m]
        value += possible.charAt(Math.floor(Math.random() * possible.length))

    S = exports.Salvus
    database = new S keyspace:'test', cb:() ->
        kv = database.key_value_store(name:'db_test1')

        tasks = []
        for i in [1...n]
            tasks.push (cb) ->
                console.log("set #{i}")
                kv.set(key:i, value:value, ttl:60, cb:cb)
        for i in [1...n]
            tasks.push (cb) ->
                console.log("delete #{i}")
                kv.delete(key:i, cb:cb)

        async.series tasks, (cb) ->
            console.log('done!')



#### handle storage sync for chunked object store

if process.argv[1] == 'storage_sync'
    exports.storage_sync(project_ids:process.argv.slice(2))
