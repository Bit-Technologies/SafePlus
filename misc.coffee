##########################################################################
#
# Misc. functions that are needed elsewhere.
#
##########################################################################
#
###############################################################################
# Copyright (c) 2013, William Stein
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
###############################################################################


# true if s.startswith(c)
exports.startswith = (s, c) ->
    return s.indexOf(c) == 0

exports.merge = (dest, objs ...) ->
    for obj in objs
        dest[k] = v for k, v of obj
    dest

# Return a random element of an array
exports.random_choice = (array) -> array[Math.floor(Math.random() * array.length)]

# Given an object map {foo:bar, ...} returns an array [foo, bar] randomly
# chosen from the object map.
exports.random_choice_from_obj = (obj) ->
    k = exports.random_choice(exports.keys(obj))
    return [k, obj[k]]

# Returns a random integer in the range, inclusive (like in Python)
exports.randint = (lower, upper) -> Math.floor(Math.random()*(upper - lower + 1)) + lower

# Like Python's string split -- splits on whitespace
exports.split = (s) -> s.match(/\S+/g)

# modifies target in place, so that the properties of target are the
# same as those of upper_bound, and each is <=.
exports.min_object = (target, upper_bounds) ->
    if not target?
        target = {}
    for prop, val of upper_bounds
        target[prop] = if target.hasOwnProperty(prop) then target[prop] = Math.min(target[prop], upper_bounds[prop]) else upper_bounds[prop]

# Returns a new object with properties determined by those of obj1 and
# obj2.  The properties in obj1 *must* all also appear in obj2.  If an
# obj2 property has value "defaults.required", then it must appear in
# obj1.  For each property P of obj2 not specified in obj1, the
# corresponding value obj1[P] is set (all in a new copy of obj1) to
# be obj2[P].
exports.defaults = (obj1, obj2) ->
    if not obj1?
        obj1 = {}
    error  = () ->
        try
            "(obj1=#{exports.to_json(obj1)}, obj2=#{exports.to_json(obj2)})"
        catch error
            ""
    if typeof(obj1) != 'object'
        # We put explicit traces before the errors in this function,
        # since otherwise they can be very hard to debug.
        console.trace()
        throw "misc.defaults -- TypeError: function takes inputs as an object #{error()}"
    r = {}
    for prop, val of obj2
        if obj1.hasOwnProperty(prop) and obj1[prop]?
            if obj2[prop] == exports.defaults.required and not obj1[prop]?
                console.trace()
                throw "misc.defaults -- TypeError: property '#{prop}' must be specified: #{error()}"
            r[prop] = obj1[prop]
        else if obj2[prop]?  # only record not undefined properties
            if obj2[prop] == exports.defaults.required
                console.trace()
                throw "misc.defaults -- TypeError: property '#{prop}' must be specified: #{error()}"
            else
                r[prop] = obj2[prop]
    for prop, val of obj1
        if not obj2.hasOwnProperty(prop)
            console.trace()
            throw "misc.defaults -- TypeError: got an unexpected argument '#{prop}' #{error()}"
    return r

# WARNING -- don't accidentally use this as a default:
exports.required = exports.defaults.required = "__!!!!!!this is a required property!!!!!!__"

# Current time in milliseconds since epoch
exports.mswalltime = (t) ->
    if t?
        return (new Date()).getTime() - t
    else
        return (new Date()).getTime()

# Current time in seconds since epoch, as a floating point number (so much more precise than just seconds).
exports.walltime = (t) ->
    if t?
        return exports.mswalltime()/1000.0 - t
    else
        return exports.mswalltime()/1000.0

# We use this uuid implementation only for the browser client.  For node code, use node-uuid.
exports.uuid = ->
    `'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        var r = Math.random()*16|0, v = c == 'x' ? r : (r&0x3|0x8);
        return v.toString(16);
    });`

exports.is_valid_uuid_string = (uuid) ->
    return typeof(uuid) == "string" and uuid.length == 36 and /[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}/i.test(uuid)
    # /[0-9a-f]{22}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i.test(uuid)

# Return a very rough benchmark of the number of times f will run per second.
exports.times_per_second = (f, max_time=5, max_loops=1000) ->
    # return number of times per second that f() can be called
    t = exports.walltime()
    i = 0
    tm = 0
    while true
        f()
        tm = exports.walltime() - t
        i += 1
        if tm >= max_time or i >= max_loops
            break
    return Math.ceil(i/tm)

# convert basic structure to a JSON string
exports.to_json = (x) ->
    JSON.stringify(x)

# convert object x to a JSON string, removing any keys that have "pass" in them.
exports.to_safe_str = (x) ->
    obj = {}
    for key of x
        if key.indexOf("pass") == -1
            obj[key] = x[key]
    return exports.to_json(obj)

# convert from a JSON string to Javascript
exports.from_json = (x) ->
    try
        JSON.parse(x)
    catch err
        console.log("from_json: error parsing #{x} (=#{exports.to_json(x)}) from JSON")
        throw err

# converts a Date object to an ISO string in UTC.
# NOTE -- we remove the +0000 (or whatever) timezone offset, since *all* machines within
# the SMC servers are assumed to be on UTC.
exports.to_iso = (d) -> (new Date(d - d.getTimezoneOffset()*60*1000)).toISOString().slice(0,-5)

# returns true if the given object has no keys
exports.is_empty_object = (obj) -> Object.keys(obj).length == 0

# returns the number of keys of an object, e.g., {a:5, b:7, d:'hello'} --> 3
exports.len = (obj) ->
    a = obj.length
    if a?
        return a
    Object.keys(obj).length

# return the keys of an object, e.g., {a:5, xyz:'10'} -> ['a', 'xyz']
exports.keys = (obj) -> (key for key of obj)

# remove first occurrence of value (just like in python);
# throws an exception if val not in list.
exports.remove = (obj, val) ->
    for i in [0...obj.length]
        if obj[i] == val
            obj.splice(i, 1)
            return
    throw "ValueError -- item not in array"

# convert an array of 2-element arrays to an object, e.g., [['a',5], ['xyz','10']] --> {a:5, xyz:'10'}
exports.pairs_to_obj = (v) ->
    o = {}
    for x in v
        o[x[0]] = x[1]
    return o

exports.obj_to_pairs = (obj) -> ([x,y] for x,y of obj)

# from http://stackoverflow.com/questions/4009756/how-to-count-string-occurrence-in-string via http://js2coffee.org/
exports.substring_count = (string, subString, allowOverlapping) ->
    string += ""
    subString += ""
    return string.length + 1 if subString.length <= 0
    n = 0
    pos = 0
    step = (if (allowOverlapping) then (1) else (subString.length))
    loop
        pos = string.indexOf(subString, pos)
        if pos >= 0
            n++
            pos += step
        else
            break
    return n

exports.max = (array) -> (array.reduce((a,b) -> Math.max(a, b)))

exports.min = (array) -> (array.reduce((a,b) -> Math.min(a, b)))

filename_extension_re = /(?:\.([^.]+))?$/
exports.filename_extension = (filename) ->
    ext = filename_extension_re.exec(filename)[1]
    if ext?
        return ext
    else
        return ''


exports.copy = (obj) ->
    r = {}
    for x, y of obj
        r[x] = y
    return r

# From http://coffeescriptcookbook.com/chapters/classes_and_objects/cloning
exports.deep_copy = (obj) ->
    if not obj? or typeof obj isnt 'object'
        return obj

    if obj instanceof Date
        return new Date(obj.getTime())

    if obj instanceof RegExp
        flags = ''
        flags += 'g' if obj.global?
        flags += 'i' if obj.ignoreCase?
        flags += 'm' if obj.multiline?
        flags += 'y' if obj.sticky?
        return new RegExp(obj.source, flags)

    newInstance = new obj.constructor()

    for key of obj
        newInstance[key] = exports.clone obj[key]

    return newInstance

# Split a pathname.  Returns an object {head:..., tail:...} where tail is
# everything after the final slash.  Either part may be empty.
# (Same as os.path.split in Python.)
exports.path_split = (path) ->
    v = path.split('/')
    return {head:v.slice(0,-1).join('/'), tail:v[v.length-1]}



exports.meta_file = (path, ext) ->
    p = exports.path_split(path)
    path = p.head
    if p.head != ''
        path += '/'
    return path + "." + p.tail + ".sage-" + ext

exports.trunc = (s, max_length) ->
    if not s?
        return s
    if not max_length?
        max_length = 1024
    if s.length > max_length
        return s.slice(0,max_length-3) + "..."
    else
        return s

exports.git_author = (first_name, last_name, email_address) -> "#{first_name} #{last_name} <#{email_address}>"

# More canonical email address -- lower case and remove stuff between + and @.
# This is mainly used for banning users.

exports.canonicalize_email_address = (email_address) ->
    # remove + part from email address:   foo+bar@example.com
    i = email_address.indexOf('+')
    if i != -1
        j = email_address.indexOf('@')
        if j != -1
            email_address = email_address.slice(0,i) + email_address.slice(j)
    # make email address lower case
    return email_address.toLowerCase()

# Delete trailing whitespace in the string s.  See
exports.delete_trailing_whitespace = (s) ->
    return s.replace(/[^\S\n]+$/gm, "")

exports.assert = (condition, mesg) ->
    if not condition
        throw mesg

exports.retry_until_success = (opts) ->
    opts = exports.defaults opts,
        f           : exports.required   # f((err) => )
        start_delay : 100             # milliseconds
        max_delay   : 30000           # milliseconds -- stop increasing time at this point
        factor      : 1.5             # multiply delay by this each time
        cb          : undefined       # called with cb() on *success* only -- obviously no way for this function to return an error

    delta = opts.start_delay
    g = () ->
        opts.f (err)->
            if err
                delta = Math.min(opts.max_delay, opts.factor * delta)
                setTimeout(g, delta)
            else
                opts.cb?()
    setTimeout(g, delta)


# Attempt (using exponential backoff) to execute the given function.
# Will keep retrying until it succeeds, then call "cb()".   You may
# call this multiple times and all callbacks will get called once the
# connection succeeds, since it keeps a stack of all cb's.
# The function f that gets called should make one attempt to do what it
# does, then on success do cb() and on failure cb(err).
# It must *NOT* call the RetryUntilSuccess callable object.
#
# Usage
#
#      @foo = retry_until_success_wrapper(f:@_foo)
#      @bar = retry_until_success_wrapper(f:@_foo, start_delay:100, max_delay:10000, exp_factor:1.5)
#
exports.retry_until_success_wrapper = (opts) ->
    _X = new RetryUntilSuccess(opts)
    return (cb) -> _X.call(cb)

class RetryUntilSuccess
    constructor: (opts) ->
        @opts = exports.defaults opts,
            f            : exports.defaults.required    # f(cb);  cb(err)
            start_delay  : 100         # initial delay beforing calling f again.  times are all in milliseconds
            max_delay    : 20000
            exp_factor   : 1.4
            max_tries    : undefined
            min_interval : 100   # if defined, all calls to f will be separated by *at least* this amount of time (to avoid overloading services, etc.)
            logname      : undefined
        if @opts.min_interval?
            if @opts.start_delay < @opts.min_interval
                @opts.start_delay = @opts.min_interval
        @f = @opts.f

    call: (cb, retry_delay) =>
        if @opts.logname?
            console.log("#{@opts.logname}(... #{retry_delay})")

        if not @_cb_stack?
            @_cb_stack = []
        if cb?
            @_cb_stack.push(cb)
        if @_calling
            return
        @_calling = true
        if not retry_delay?
            @attempts = 0

        if @opts.logname?
            console.log("actually calling -- #{@opts.logname}(... #{retry_delay})")

        g = () =>
            if @opts.min_interval?
                @_last_call_time = exports.mswalltime()
            @f (err) =>
                @attempts += 1
                @_calling = false
                if err? and err
                    if @opts.max_tries? and @attempts >= @opts.max_tries
                        while @_cb_stack.length > 0
                            @_cb_stack.pop()(err)
                        return
                    if not retry_delay?
                        retry_delay = @opts.start_delay
                    else
                        retry_delay = Math.min(@opts.max_delay, @opts.exp_factor*retry_delay)
                    f = () =>
                        @call(undefined, retry_delay)
                    setTimeout(f, retry_delay)
                else
                    while @_cb_stack.length > 0
                        @_cb_stack.pop()()
        if not @_last_call_time? or not @opts.min_interval?
            g()
        else
            w = exports.mswalltime(@_last_call_time)
            if w < @opts.min_interval
                setTimeout(g, @opts.min_interval - w)
            else
                g()

# WARNING: params below have different semantics than above; these are what *really* make sense....
exports.eval_until_defined = (opts) ->
    opts = exports.defaults opts,
        code         : exports.required
        start_delay  : 100    # initial delay beforing calling f again.  times are all in milliseconds
        max_time     : 10000  # error if total time spent trying will exceed this time
        exp_factor   : 1.4
        cb           : exports.required # cb(err, eval(code))
    delay = undefined
    total = 0
    f = () ->
        result = eval(opts.code)
        if result?
            opts.cb(false, result)
        else
            if not delay?
                delay = opts.start_delay
            else
                delay *= opts.exp_factor
            total += delay
            if total > opts.max_time
                opts.cb("failed to eval code within #{opts.max_time}")
            else
                setTimeout(f, delay)
    f()




# Class to use for mapping a collection of strings to characters (e.g., for use with diff/patch/match).
class exports.StringCharMapping
    constructor: (opts={}) ->
        opts = exports.defaults opts,
            to_char   : undefined
            to_string : undefined
        @_to_char   = {}
        @_to_string = {}
        @_next_char = 'A'
        if opts.to_string?
            for ch, st of opts.to_string
                @_to_string[ch] = st
                @_to_char[st]  = ch
        if opts.to_char?
            for st,ch of opts.to_char
                @_to_string[ch] = st
                @_to_char[st]   = ch
        @_find_next_char()

    _find_next_char: () =>
        loop
            @_next_char = String.fromCharCode(@_next_char.charCodeAt(0) + 1)
            break if not @_to_string[@_next_char]?

    to_string: (strings) =>
        t = ''
        for s in strings
            a = @_to_char[s]
            if a?
                t += a
            else
                t += @_next_char
                @_to_char[s] = @_next_char
                @_to_string[@_next_char] = s
                @_find_next_char()
        return t

    to_array: (string) =>
        return (@_to_string[s] for s in string)

# Given a string s, return the string obtained by deleting all later duplicate characters from s.
exports.uniquify_string = (s) ->
    seen_already = {}
    t = ''
    for c in s
        if not seen_already[c]?
            t += c
            seen_already[c] = true
    return t


# Return string t=s+'\n'*k so that t ends in at least n newlines.
# Returns s itself (so no copy made) if s already ends in n newlines (a common case).
### -- not used
exports.ensure_string_ends_in_newlines = (s, n) ->
    j = s.length-1
    while j >= 0 and j >= s.length-n and s[j] == '\n'
        j -= 1
    # Now either j = -1 or s[j] is not a newline (and it is the first character not a newline from the right).
    console.log(j)
    k = n - (s.length - (j + 1))
    console.log(k)
    if k == 0
        return s
    else
        return s + Array(k+1).join('\n')   # see http://stackoverflow.com/questions/1877475/repeat-character-n-times
###




# Used in the database, etc., for different types of users of a project

exports.PROJECT_GROUPS = ['owner', 'collaborator', 'viewer', 'invited_collaborator', 'invited_viewer']


# turn an arbitrary string into a nice clean identifier that can safely be used in an URL
exports.make_valid_name = (s) ->
    # for now we just delete anything that isn't alphanumeric.
    # See http://stackoverflow.com/questions/9364400/remove-not-alphanumeric-characters-from-string-having-trouble-with-the-char/9364527#9364527
    # whose existence surprised me!
    return s.replace(/\W/g, '_').toLowerCase()







