###
#
# Library for working with JSON messages for Salvus.
#
# (c) 2012, William Stein
#
# We use functions to work with messages to ensure some level of
# consistency, defaults, and avoid errors from typos, etc.
#
###

misc     = require('misc')
defaults = misc.defaults
required = defaults.required


message = (obj) ->
    exports[obj.event] = (opts={}) ->
        if opts.event?
            throw "ValueError: must not define 'event' when calling message creation function (opts=#{JSON.stringify(opts)}, obj=#{JSON.stringify(obj)})"
        defaults(opts, obj)

############################################
# Compute server messages
#############################################

message
    event            : 'compute_server_status'
    running_children : undefined    # list of child process names (e.g., 'sage_server', 'console_server', 'project_server') that are running


############################################
# Sage session management; executing code
#############################################

# hub --> sage_server&console_server, etc. and browser --> hub
message
    event        : 'start_session'
    type         : required           # "sage", "console";  later this could be "R", "octave", etc.
    # TODO: project_id should be required
    project_id   : undefined          # the project that this session will start in
    session_uuid : undefined          # set by the hub -- client setting this will be ignored.
    params       : undefined          # extra parameters that control the type of session
    id           : undefined
    limits       : undefined

# hub --> browser
message
    event         : 'session_started'
    id            : undefined
    session_uuid  : undefined
    limits        : undefined
    data_channel  : undefined # The data_channel is a single UTF-16
                              # character; this is used for
                              # efficiently sending and receiving
                              # non-JSON data (except channel
                              # '\u0000', which is JSON).
                            #

# client <--> hub <--> local_hub
# info = {
#         sage_sessions    : {uuid:{desc:info.desc, status:info.status}, ...},
#         console_sessions : {uuid:{}, ...}
#        }
message
    event         : 'project_session_info'
    id            : undefined
    project_id    : undefined
    info          : undefined

#
# A period ping message must usually be sent by the client to keep a
# worksheet/console open, except when worksheet/console is explicitly
# put in a special (screen-like/nohup) mode.
#
# client --> hub
message
    event         : 'ping_session'
    id            : undefined
    session_uuid  : undefined


# client --> hub
message
    event        : 'connect_to_session'
    id           : undefined
    type         : required
    project_id   : required
    session_uuid : required
    params       : undefined          # extra parameters that control the type of session -- if we have to create a new one

message
    event         : 'session_connected'
    id            : undefined
    session_uuid  : required
    data_channel  : undefined  # used for certain types of sessions


# sage_server&console_server --> hub
message
    event  : 'session_description'
    pid    : required
    limits : undefined

# client --> hub --> session servers
message
    event        : 'send_signal'
    id           : undefined
    session_uuid : undefined   # from browser-->hub this must be set
    pid          : undefined   # from hub-->sage_server this must be set
    signal       : 2           # 2 = SIGINT, 3 = SIGQUIT, 9 = SIGKILL

message
    event        : 'signal_sent'
    id           : required

# Restart the underlying Sage process for this session; the session
# with the given id still exists, it's just that the underlying sage
# process got restarted.
# client --> hub
message
    event        : 'restart_session'
    session_uuid : required
    id           : undefined

# client <----> hub <--> sage_server
message
    event        : 'terminate_session'
    project_id   : undefined
    session_uuid : undefined
    reason       : undefined
    done         : undefined

# browser --> hub --> sage_server
message
    event        : 'execute_code'
    id           : undefined
    code         : required
    data         : undefined
    session_uuid : undefined
    preparse     : true
    allow_cache  : true

# Output resulting from evaluating code that is displayed by the browser.
# sage_server --> local hub --> hubs --> clients
message
    event        : 'output'
    id           : undefined   # the id for this particular computation
    stdout       : undefined   # plain text stream
    stderr       : undefined   # error text stream -- colored to indicate an error
    html         : undefined   # arbitrary html stream
    tex          : undefined   # tex/latex stream -- is an object {tex:..., display:...}
    hide         : undefined   # 'input' or 'output'; hide display of given component of cell
    show         : undefined   # 'input' or 'output'; show display of given component of cell
    auto         : undefined   # true or false; sets whether or not cell auto-executess on process restart
    javascript   : undefined   # javascript code evaluation stream (see also 'execute_javascript' to run code directly in browser that is not part of the output stream).
    interact     : undefined   # create an interact layout defined by a JSON object
    obj          : undefined   # used for passing any JSON-able object along as output; this is used, e.g., by interact.
    file         : undefined   # used for passing a file -- is an object {filename:..., uuid:..., show:true}; the file is at https://cloud.sagemath.com/blobs/filename?uuid=[the uuid]
    done         : false       # the sequences of messages for a given code evaluation is done.
    session_uuid : undefined   # the uuid of the session that produced this output
    once         : undefined   # if given, message is transient; it is not saved by the worksheet, etc.

# This message tells the client to execute the given Javascript code
# in the browser.  (For safety, the client may choose to ignore this
# message.)  If coffeescript==true, then the code is assumed to be
# coffeescript and is first compiled to Javascript.  This message is
# "out of band", i.e., not meant to be part of any particular output
# cell.  That is why there is no id key.

# sage_server --> hub --> client
message
    event        : 'execute_javascript'
    session_uuid : undefined              # set by the hub, since sage_server doesn't (need to) know the session_uuid.
    code         : required
    data         : undefined
    coffeescript : false


############################################
# Session Introspection
#############################################
# An introspect message from the client can result in numerous types
# of responses (but there will only be one response).  The id of the
# message from hub back to client will match the id of the message
# from client to hub; the client is responsible for deciding
# what/where/how to deal with the message.

# client --> hub --> sage_server
message
    event              : 'introspect'
    id                 : undefined
    session_uuid       : required
    line               : required
    preparse           : true

# hub --> client (can be sent in response to introspect message)
message
    event       : 'introspect_completions'
    id          : undefined   # match id of 'introspect' message
    target      : required    # 'Ellip'
    completions : required    # ['sis', 'ticCurve', 'ticCurve_from_c4c6', ...]

# hub --> client  (can be sent in response to introspect message)
message
    event       : 'introspect_docstring'
    id          : undefined
    target      : required
    docstring   : required

# hub --> client
message
    event       : 'introspect_source_code'
    id          : undefined
    target      : required
    source_code : required





############################################
# CodeMirror editor sessions
#############################################

# client --> hub --> local_hub
message
    event        : 'codemirror_get_session'
    path         : undefined   # at least one of path or session_uuid must be defined
    session_uuid : undefined
    project_id   : undefined
    id           : undefined

# local_hub --> hub --> client
message
    event        : 'codemirror_session'
    id           : undefined
    session_uuid : required
    path         : required    # absolute path
    content      : required
    chat         : required

# A list of edits that should be applied, along with the
# last version of edits received before.
# client <--> hub <--> local_hub
message
    event            : 'codemirror_diffsync'
    id               : undefined
    session_uuid     : undefined
    edit_stack       : required
    last_version_ack : required

# Suggest to the connected big hub that there is data ready to be synced:
# local_hub --> hub --> client
message
    event            : 'codemirror_diffsync_ready'
    session_uuid     : undefined

# Hub uses this message to tell client that client should try to sync later, since hub is
# busy now with some other locking sync operation.
# local_hub <-- hub
message
    event            : 'codemirror_diffsync_retry_later'
    id               : undefined


# Write out whatever is on local_hub to the physical disk
# client --> hub --> local_hub
message
    event        : 'codemirror_write_to_disk'
    id           : undefined
    session_uuid : undefined

# Replace what is on local_hub by what is on physical disk (will push out a
# codemirror_change message, so any browser client has a chance to undo this).
# client --> hub --> local_hub
message
    event        : 'codemirror_read_from_disk'
    id           : undefined
    session_uuid : undefined

# Request the current content of the file.   This may be
# used to refresh the content in a client, even after a session started.
# client --> hub --> local_hub
message
    event        : 'codemirror_get_content'
    id           : undefined
    session_uuid : undefined

# Sent in response to a codemirror_get_content message.
# local_hub --> hub --> client
message
    event        : 'codemirror_content'
    id           : undefined
    content      : required

# Disconnect a client from a codemirror editing session.
# local_hub --> hub
# client --> hub
message
    event        : 'codemirror_disconnect'
    id           : undefined
    session_uuid : required

# Broadcast mesg to all clients connected to this session.
# This is used for cursors and out-of-band chat.
# client <--> hub <--> local_hub
message
    event        : 'codemirror_bcast'
    session_uuid : required
    self         : undefined    # if true, message will also be sent to self from global hub.
    name         : undefined
    color        : undefined
    date         : undefined
    mesg         : required     # arbitrary message, can have event, etc., attributes.

# This is used so that a client can execute code in the Sage process that is running
# controlled by a codemirror sync session.  This is mainly used to implement interact
# in synchronized worksheets that are embedded in a single codemirror editor.
# client --> hub --> local_hub --> sage_server
message
    event        : 'codemirror_execute_code'
    id           : undefined
    code         : required
    data         : undefined
    session_uuid : required
    preparse     : true

# Introspection in the context of a codemirror editing session.
# client --> hub --> sage_server
message
    event              : 'codemirror_introspect'
    id                 : undefined
    session_uuid       : required
    line               : required
    preparse           : true

# client --> hub --> local_hub
message
    event        : 'codemirror_send_signal'
    id           : undefined
    session_uuid : required
    signal       : 2           # 2 = SIGINT, 3 = SIGQUIT, 9 = SIGKILL



############################################
# Ping/pong
#############################################
# browser --> hub
message
    event   : 'ping'
    id      : undefined

# hub --> browser;   sent in response to a ping
message
    event   : 'pong'
    id      : undefined

############################################
# Account Management
#############################################

# client --> hub
message
    event          : 'create_account'
    id             : undefined
    first_name     : required
    last_name      : required
    email_address  : required
    password       : required
    agreed_to_terms: required

# hub --> client
message
    event          : 'account_creation_failed'
    id             : required
    reason         : required

# client <--> hub
message
    event          : 'email_address_availability'
    id             : undefined
    email_address  : required
    is_available   : undefined

# client --> hub
message
    id             : undefined
    event          : 'sign_in'
    email_address  : required
    password       : required
    remember_me    : false

# client --> hub
message
    id             : undefined
    event          : 'sign_in_failed'
    email_address  : required
    reason         : required

# hub --> client; sent in response to either create_account or log_in
message
    event          : 'signed_in'
    id             : undefined     # message uuid
    account_id     : required      # uuid of user's account
    first_name     : required      # user's first name
    last_name      : required      # user's last name
    email_address  : required      # address they just signed in using
    remember_me    : required      # true if sign in accomplished via remember_me cookie; otherwise, false.

# client --> hub
message
    event          : 'sign_out'
    id             : undefined

# hub --> client
message
    event          : 'signed_out'
    id             : undefined

# client --> hub
message
    event          : 'change_password'
    id             : undefined
    email_address  : required
    old_password   : required
    new_password   : required

# hub --> client
# if error is true, that means the password was not changed; would
# happen if password is wrong (message:'invalid password').
message
    event          : 'changed_password'
    id             : undefined
    error          : undefined

# client --> hub: "please send a password reset email"
message
    event         : "forgot_password"
    id            : undefined
    email_address : required

# hub --> client  "a password reset email was sent, or there was an error"
message
    event         : "forgot_password_response"
    id            : undefined
    error         : false

# client --> hub: "reset a password using this id code that was sent in a password reset email"
message
    event         : "reset_forgot_password"
    id            : undefined
    reset_code    : required
    new_password  : required

message
    event         : "reset_forgot_password_response"
    id            : undefined
    error         : false

# client --> hub
message
    event             : 'change_email_address'
    id                : undefined
    account_id        : required
    old_email_address : required
    new_email_address : required
    password          : required

# hub --> client
message
    event               : 'changed_email_address'
    id                  : undefined
    error               : false  # some other error
    ttl                 : undefined   # if user is trying to change password too often, this is time to wait


############################################
# Account Settings
#############################################

# client --> hub
message
    event          : "get_account_settings"
    id             : undefined
    account_id     : required

# settings that require the password in the message (so user must
# explicitly retype password to change these):
exports.restricted_account_settings =
    plan_id              : undefined
    plan_name            : undefined
    plan_starttime       : undefined
    storage_limit        : undefined
    session_limit        : undefined
    max_session_time     : undefined
    ram_limit            : undefined
    support_level        : undefined
    email_address        : undefined
    connect_Github       : undefined
    connect_Google       : undefined
    connect_Dropbox      : undefined

# these can be changed without additional re-typing of the password
# (of course, user must have somehow logged in):
exports.unrestricted_account_settings =
    first_name           : required
    last_name            : required
    default_system       : required
    evaluate_key         : required
    email_new_features   : required
    email_maintenance    : required
    enable_tooltips      : required
    autosave             : required   # time in seconds or 0 to disable
    terminal             : required   # time in seconds or 0 to disable

exports.account_settings_defaults =
    plan_id            : 0  # the free trial plan
    default_system     : 'sage'
    evaluate_key       : 'shift-enter'
    email_new_features : true
    email_maintenance  : true
    enable_tooltips    : true
    connect_Github     : ''
    connect_Google     : ''
    connect_Dropbox    : ''
    autosave           : 180
    terminal           : {font_size:14, color_scheme:'default'}

# client <--> hub
message(
    misc.merge({},
        event                : "account_settings"
        account_id           : required
        id                   : undefined
        password             : undefined   # only set when sending message from client to hub; must be set to change restricted settings
        exports.unrestricted_account_settings,
        exports.restricted_account_settings
    )
)

message
    event : 'account_settings_saved'
    id    : undefined

message
    event : 'error'
    id    : undefined
    error : undefined

message
    event : 'success'
    id    : undefined

# You need to reconnect.
message
    event : 'reconnect'
    id    : undefined
    reason : undefined  # optional to make logs more informative



############################################
# Scratch worksheet
#############################################
message
    event : 'save_scratch_worksheet'
    data  : required
    id    : undefined

message
    event : 'load_scratch_worksheet'
    id    : undefined

message
    event : 'delete_scratch_worksheet'
    id    : undefined

message
    event : 'scratch_worksheet_loaded'
    id    : undefined
    data  : undefined   # undefined means there is no scratch worksheet yet

############################################
# User Feedback
#############################################

message
    event       : 'report_feedback'
    id          : undefined
    category    : required            # 'bug', 'idea', 'comment'
    description : required            # text
    nps         : undefined           # net promotor score; integer 1,2,...,9

message
    event       : 'feedback_reported'
    error       : undefined
    id          : required

message
    event       : 'get_all_feedback_from_user'
    error       : undefined
    id          : undefined

message
    event       : 'all_feedback_from_user'
    id          : required
    error       : undefined
    data        : required  # JSON list of objects


######################################################################################
# This is a message that goes
#      hub --> client
# In response, the client grabs "/cookies?id=...,set=...,get=..." via an AJAX call.
# During that call the server can get/set HTTP-only cookies.
######################################################################################
message
    event       : 'cookies'
    id          : required
    set         : undefined  # name of a cookie to set
    get         : undefined  # name of a cookie to get




###################################################################################
#
# Project Server <---> Hub interaction
#
# These messages are mainly focused on working with individual projects.
#
# Architecture:
#
#   * The database stores a files object (with the file tree), logs
#     (of each branch) and a sequence of git bundles that when
#     combined together give the complete history of the repository.
#     Total disk usage per project is limited by hard/soft disk quota,
#     and includes the space taken by the revision history (the .git
#     directory).
#
#   * A project should only be opened by at most one project_server at
#     any given time (not implemented: if this is violated then we'll
#     merge the resulting conflicting repo's.)
#
#   * Which project_server that has a project opened is stored in the
#     database.  If a hub cannot connect to a given project server,
#     the hub assigns a new project_server for the project and opens
#     the project on the new project_server.  (The error also gets
#     logged to the database.)  All hubs will use this new project
#     server henceforth.
#
###################################################################################

# The open_project message causes the project_server to create a new
# project or prepare to receive one (as a sequence of blob messages)
# from a hub.
#
# hub --> project_server
message
    event        : 'open_project'
    id           : required
    project_id   : required  # uuid of the project, which impacts
                             # where project is extracted, etc.
    quota        : required  # Maximum amount of disk space/inodes this
                             # project can use.  This is an object
                             #    {disk:{soft:megabytes, hard:megabytes}, inode:{soft:num, hard:num}}
    idle_timeout : required  # A time in seconds; if the project_server
                             # does not receive any messages related
                             # to this project for this many seconds,
                             # then it does the same thing as when
                             # receiving a 'close_project' message.
    ssh_public_key: required # ssh key of the one UNIX user that is allowed to access this account (this is running the hub).

# A project_server sends the project_opened message to the hub once
# the project_server has received and unbundled all bundles that
# define a project.
# project_server --> hub
message
    event : 'project_opened'
    id    : required

# A hub sends the save_project message to a project_server to request
# that the project_server save a snapshot of this project.  On
# success, the project_server will respond by sending a project_saved
# message then sending individual the bundles n.bundle for n >=
# starting_bundle_number.
#
# client --> hub --> project_server
message
    event                  : 'save_project'
    id                     : undefined
    project_id             : required    # uuid of a project

# The project_saved message is sent to a hub by a project_server when
# the project_servers creates a new snapshot of the project in
# response to a save_project message.
# project_server --> hub
message
    event          : 'project_saved'
    id             : required       # message id, which matches the save_project message
    bundle_uuids   : required       # {uuid:bundle_number, uuid:bundle_number, ...} -- bundles are sent as blobs in separate messages.




######################################################################
# Execute a program in a given project
######################################################################

# client --> project
message
    event      : 'project_exec'
    id         : undefined
    project_id : undefined
    path       : ''   # if relative, is a path under home; if absolute is what it is.
    command    : required
    args       : []
    timeout    : 10          # maximum allowed time, in seconds.
    max_output : undefined   # maximum number of characters in the output
    bash       : false       # if true, args are ignored and command is run as a bash command
    err_on_exit : true       # if exit code is nonzero send error return message instead of the usual output.

message
    event      : 'project_exec_output'
    id         : required
    stdout     : required
    stderr     : required
    exit_code  : required



#############################################################################

# A hub sends this message to the project_server to request that the
# project_server close the project.  This immediately deletes all files
# and clears up all resources allocated for this project.  So make
# sure to send a save_project message first!
#
# client --> hub --> project_server
message
    event         : 'close_project'
    id            : undefined
    project_id    : required

# A project_server sends this message in response to a close_project
# message, to indicate that files have been cleaned up and relevant
# processes killed.
# project_server --> hub
message
    event : 'project_closed'
    id    : required     # id of message (matches close_project message above)

# The read_file_from_project message is sent by the hub to request
# that the project_server read a file from a project and send it back
# to the hub as a blob.  Also sent by client to hub to request a file
# or directory. If path is a directory, the optional archive field
# specifies how to create a single file archive, with supported
# options including:  'tar', 'tar.bz2', 'tar.gz', 'zip', '7z'.
#
# client --> hub --> project_server
message
    event        : 'read_file_from_project'
    id           : undefined
    project_id   : required
    path         : required
    archive      : 'tar.bz2'

# The file_read_from_project message is sent by the project_server
# when it finishes reading the file from disk.
# project_server --> hub
message
    event        : 'file_read_from_project'
    id           : required
    data_uuid    : required  # The project_server will send the raw data of the file as a blob with this uuid.
    archive      : undefined  # if defined, means that file (or directory) was archived (tarred up) and this string was added to end of filename.


# hub --> client
message
    event        : 'temporary_link_to_file_read_from_project'
    id           : required
    url          : required

# The client sends this message to the hub in order to write (or
# create) a plain text file (binary files not allowed, since sending
# them via JSON makes no sense).
# client --> hub
message
    event        : 'read_text_file_from_project'
    id           : undefined
    project_id   : required
    path         : required

# hub --> client
message
    event        : 'text_file_read_from_project'
    id           : required
    content      : required

# client --> hub --> project_server
message
    event        : 'make_directory_in_project'
    id           : required
    project_id   : required
    path         : required

# project_server --> hub --> client
message
    event        : 'directory_made_in_project'
    id           : required

# client --> hub --> project_server
message
    event        : 'move_file_in_project'
    id           : undefined
    project_id   : required
    src          : required
    dest         : required

# project_server --> hub --> client
message
    event        : 'file_moved_in_project'
    id           : required

# client --> hub --> project_server
message
    event        : 'remove_file_from_project'
    id           : undefined
    project_id   : required
    path         : required


# The write_file_to_project message is sent from the hub to the
# project_server to tell the project_server to write a file to a
# project.  If the path includes directories that don't exists,
# they are automatically created (this is in fact the only way
# to make a new directory).
# hub --> project_server
message
    event        : 'write_file_to_project'
    id           : required
    project_id   : required
    path         : required
    data_uuid    : required  # hub sends raw data as a blob with this uuid immediately.

# The client sends this message to the hub in order to write (or
# create) a plain text file (binary files not allowed, since sending
# them via JSON makes no sense).
# client --> hub
message
    event        : 'write_text_file_to_project'
    id           : undefined
    project_id   : required
    path         : required
    content      : required

# The file_written_to_project message is sent by a project_server to
# confirm successful write of the file to the project.
# project_server --> hub
message
    event        : 'file_written_to_project'
    id           : required

############################################
# Permament blob store
############################################

# Remove ttl from a blob and associate the blob with a project.
message
    event       : 'save_blobs_to_project'
    id          : undefined   # message id, as usual
    project_id  : required    # id of project that contains blob associated to
    blob_ids    : required   # list of blobs to attach permanently to the project

############################################
# Branches
############################################
# client --> hub
message
    event        : 'create_project_branch'
    id           : undefined
    project_id   : required
    branch       : required

message
    event        : 'checkout_project_branch'
    id           : undefined
    project_id   : required
    branch       : required

message
    event         : 'delete_project_branch'
    id            : undefined
    project_id   : required
    branch        : required

message
    event         : 'merge_project_branch'
    id            : undefined
    project_id   : required
    branch        : required

############################################
# Managing multiple projects
############################################

# client --> hub
message
    event      : 'create_project'
    id         : undefined
    title      : required
    description: required
    public     : required

# hub --> client
message
    event      : 'project_created'
    id         : required
    project_id : required

# client --> hub
message
    event      : 'get_projects'
    id         : undefined

# hub --> client
message
    event      : 'all_projects'
    id         : required
    projects   : required     # [{project_id:, type: , title:, last_edited:}, ...]


# client --> hub
message
    event      : 'update_project_data'
    id         : undefined
    project_id : required
    data       : required     # an object; sets the fields in this object, and leaves alone the rest

# When project data is changed by one client, the following is sent to
# all clients that have access to this project (owner or collaborator).
# hub --> client
message
    event      : 'project_data_updated'
    id         : undefined
    project_id : required



# hub --> client(s)
message
    event      : 'project_list_updated'

