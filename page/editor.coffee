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


##################################################
# Editor for files in a project

# Show button labels if there are at most this many file tabs opened.
# This is in exports so that an elite user could customize this by doing, e.g.,
#    require('editor').SHOW_BUTTON_LABELS=0
exports.SHOW_BUTTON_LABELS = 4

MAX_LATEX_ERRORS   = 10
MAX_LATEX_WARNINGS = 50

MIN_SPLIT = 0.02
MAX_SPLIT = 0.98  # maximum pane split proportion for editing

TOOLTIP_DELAY = delay: {show: 500, hide: 100}

async = require('async')

message = require('message')

{salvus_client} = require('salvus_client')
{EventEmitter}  = require('events')
{alert_message} = require('alerts')

feature = require("feature")
IS_MOBILE = feature.IS_MOBILE

misc = require('misc')
misc_page = require('misc_page')
# TODO: undo doing the import below -- just use misc.[stuff] is more readable.
{copy, trunc, from_json, to_json, keys, defaults, required, filename_extension, len, path_split, uuid} = require('misc')

syncdoc = require('syncdoc')

top_navbar =  $(".salvus-top_navbar")

codemirror_associations =
    c      : 'text/x-c'
    'c++'  : 'text/x-c++src'
    cql    : 'text/x-sql'
    cpp    : 'text/x-c++src'
    cc     : 'text/x-c++src'
    conf   : 'nginx'   # should really have a list of different types that end in .conf and autodetect based on heuristics, letting user change.
    csharp : 'text/x-csharp'
    'c#'   : 'text/x-csharp'
    coffee : 'coffeescript'
    css    : 'css'
    diff   : 'text/x-diff'
    dtd    : 'application/xml-dtd'
    e      : 'text/x-eiffel'
    ecl    : 'ecl'
    f      : 'text/x-fortran'    # https://github.com/mgaitan/CodeMirror/tree/be73b866e7381da6336b258f4aa75fb455623338/mode/fortran
    f90    : 'text/x-fortran'
    f95    : 'text/x-fortran'
    h      : 'text/x-c++hdr'
    hs     : 'text/x-haskell'
    lhs    : 'text/x-haskell'
    html   : 'htmlmixed'
    java   : 'text/x-java'
    jl     : 'text/x-julia'
    js     : 'javascript'
    json   : 'javascript'
    lua    : 'lua'
    m      : 'text/x-octave'
    md     : 'gfm2'
    ml     : 'text/x-ocaml'
    mysql  : 'text/x-sql'
    patch  : 'text/x-diff'
    gp     : 'text/pari'
    go     : 'text/x-go'
    pari   : 'text/pari'
    php    : 'php'
    py     : 'python'
    pyx    : 'python'
    pl     : 'text/x-perl'
    r      : 'r'
    rst    : 'rst'
    rb     : 'text/x-ruby'
    ru     : 'text/x-ruby'
    sage   : 'python'
    sagews : 'sagews'
    scala  : 'text/x-scala'
    sh     : 'shell'
    spyx   : 'python'
    sql    : 'text/x-sql'
    txt    : 'text'
    tex    : 'stex2'
    toml   : 'text/x-toml'
    bib    : 'stex'
    bbl    : 'stex'
    xml    : 'xml'
    xsl    : 'xsl'
    yaml   : 'yaml'
    ''     : 'text'

file_associations = exports.file_associations = {}
for ext, mode of codemirror_associations
    name = mode
    i = name.indexOf('x-')
    if i != -1
        name = name.slice(i+2)
    name = name.replace('src','')
    file_associations[ext] =
        editor : 'codemirror'
        binary : false
        icon   : 'fa-file-code-o'
        opts   : {mode:mode}
        name   : name

file_associations['tex'] =
    editor : 'latex'
    icon   : 'fa-file-excel-o'
    opts   : {mode:'stex2', indent_unit:4, tab_size:4}
    name   : "latex"
#file_associations['tex'] =  # TODO: only for TESTING!!!
#    editor : 'html-md'
#    icon   : 'fa-file-code-o'
#    opts   : {indent_unit:4, tab_size:4, mode:'stex2'}


file_associations['html'] =
    editor : 'html-md'
    icon   : 'fa-file-code-o'
    opts   : {indent_unit:4, tab_size:4, mode:'htmlmixed'}
    name   : "html"

file_associations['md'] =
    editor : 'html-md'
    icon   : 'fa-file-code-o'
    opts   : {indent_unit:4, tab_size:4, mode:'gfm2'}
    name   : "markdown"

file_associations['rst'] =
    editor : 'html-md'
    icon   : 'fa-file-code-o'
    opts   : {indent_unit:4, tab_size:4, mode:'rst'}
    name   : "ReST"

file_associations['mediawiki'] = file_associations['wiki'] =
    editor : 'html-md'
    icon   : 'fa-file-code-o'
    opts   : {indent_unit:4, tab_size:4, mode:'mediawiki'}
    name   : "MediaWiki"

file_associations['sass'] =
    editor : 'codemirror'
    icon   : 'fa-file-code-o'
    opts   : {mode:'text/x-sass', indent_unit:2, tab_size:2}
    name   : "SASS"

file_associations['css'] =
    editor : 'codemirror'
    icon   : 'fa-file-code-o'
    opts   : {mode:'css', indent_unit:4, tab_size:4}
    name   : "CSS"

file_associations['term'] =
    editor : 'terminal'
    icon   : 'fa-terminal'
    opts   : {}
    name   : "Terminal"

file_associations['ipynb'] =
    editor : 'ipynb'
    icon   : 'fa-list-alt'
    opts   : {}
    name   : "ipython notebook"

for ext in ['png', 'jpg', 'gif', 'svg']
    file_associations[ext] =
        editor : 'image'
        icon   : 'fa-file-image-o'
        opts   : {}
        name   : ext
        binary : true
        exclude_from_menu : true

file_associations['pdf'] =
    editor : 'pdf'
    icon   : 'fa-file-pdf-o'
    opts   : {}
    name   : 'pdf'
    binary : true
    exclude_from_menu : true

file_associations['tasks'] =
    editor : 'tasks'
    icon   : 'fa-tasks'
    opts   : {}
    name   : 'task list'

file_associations['course'] =
    editor : 'course'
    icon   : 'fa-graduation-cap'
    opts   : {}
    name   : 'course'


file_associations['sage-history'] =
    editor : 'history'
    icon   : 'fa-history'
    opts   : {}
    name   : 'sage history'
    exclude_from_menu : true

initialize_new_file_type_list = () ->
    file_type_list = $(".smc-new-file-type-list")
    file_types_so_far = {}
    v = misc.keys(file_associations)
    v.sort()

    for ext in v
        if not ext
            continue
        data = file_associations[ext]
        if data.exclude_from_menu
            continue
        if data.name? and not file_types_so_far[data.name]
            file_types_so_far[data.name] = true
            e = $("<li><a href='#new-file' data-ext='#{ext}'><i class='fa #{data.icon}'></i> <span style='text-transform:capitalize'>#{data.name} </span> <span class='lighten'>(.#{ext})</span></a></li>")
            file_type_list.append(e)

initialize_new_file_type_list()

exports.file_icon_class = file_icon_class = (ext) ->
    if (file_associations[ext]? and file_associations[ext].icon?) then file_associations[ext].icon else 'fa-file-o'

PUBLIC_ACCESS_UNSUPPORTED = ['terminal','latex','history','tasks','course','ipynb']

# public access file types *NOT* yet supported
# (this should quickly shrink to zero)
exports.public_access_supported = (filename) ->
    ext = filename_extension(filename)
    x = file_associations[ext]
    if x?.editor in PUBLIC_ACCESS_UNSUPPORTED
        return false
    else
        return true

# Multiplex'd worksheet mode

diffsync = require('diffsync')
MARKERS  = diffsync.MARKERS

sagews_decorator_modes = [
    ['coffeescript', 'coffeescript'],
    ['cython'      , 'cython'],
    ['file'        , 'text'],
    ['fortran'     , 'text/x-fortran'],
    ['html'        , 'htmlmixed'],
    ['javascript'  , 'javascript'],
    ['latex'       , 'stex']
    ['lisp'        , 'ecl'],
    ['md'          , 'gfm2'],
    ['gp'          , 'text/pari'],
    ['go'          , 'text/x-go']
    ['perl'        , 'text/x-perl'],
    ['python3'     , 'python'],
    ['python'      , 'python'],
    ['ruby'        , 'text/x-ruby'],   # !! more specific name must be first or get mismatch!
    ['r'           , 'r'],
    ['sage'        , 'python'],
    ['script'      , 'shell'],
    ['sh'          , 'shell'],
    ['julia'       , 'text/x-julia'],
    ['wiki'        , 'mediawiki'],
    ['mediawiki'   , 'mediawiki']
]

exports.define_codemirror_sagews_mode = () ->

    # not using these two gfm2 and htmlmixed2 modes, with their sub-latex mode, since
    # detection of math isn't good enough.  e.g., \$ causes math mode and $ doesn't seem to...   \$500 and $\sin(x)$.
    CodeMirror.defineMode "gfm2", (config) ->
        options = []
        for x in [['$$','$$'], ['$','$'], ['\\[','\\]'], ['\\(','\\)']]
            options.push
                open  : x[0]
                close : x[1]
                mode  : CodeMirror.getMode(config, 'stex')
        return CodeMirror.multiplexingMode(CodeMirror.getMode(config, "gfm"), options...)

    CodeMirror.defineMode "htmlmixed2", (config) ->
        options = []
        for x in [['$$','$$'], ['$','$'], ['\\[','\\]'], ['\\(','\\)']]
            options.push
                open  : x[0]
                close : x[1]
                mode  : CodeMirror.getMode(config, mode)
        return CodeMirror.multiplexingMode(CodeMirror.getMode(config, "htmlmixed"), options...)

    CodeMirror.defineMode "stex2", (config) ->
        options = []
        for x in ['sagesilent', 'sageblock']
            options.push
                open  : "\\begin{#{x}}"
                close : "\\end{#{x}}"
                mode  : CodeMirror.getMode(config, 'sagews')
        options.push
            open  : "\\sage{"
            close : "}"
            mode  : CodeMirror.getMode(config, 'sagews')
        return CodeMirror.multiplexingMode(CodeMirror.getMode(config, "stex"), options...)

    CodeMirror.defineMode "cython", (config) ->
        # TODO: need to figure out how to do this so that the name
        # of the mode is cython
        return CodeMirror.multiplexingMode(CodeMirror.getMode(config, "python"))

    CodeMirror.defineMode "sagews", (config) ->
        options = []
        close = new RegExp("[#{MARKERS.output}#{MARKERS.cell}]")
        for x in sagews_decorator_modes
            # NOTE: very important to close on both MARKERS.output *and* MARKERS.cell,
            # rather than just MARKERS.cell, or it will try to
            # highlight the *hidden* output message line, which can
            # be *enormous*, and could take a very very long time, but is
            # a complete waste, since we never see that markup.
            options.push
                open  : "%"+x[0]
                close : close
                mode  : CodeMirror.getMode(config, x[1])

        return CodeMirror.multiplexingMode(CodeMirror.getMode(config, "python"), options...)

    ###
    $.get '/static/codemirror-extra/data/sage-completions.txt', (data) ->
        s = data.split('\n')
        sagews_hint = (editor) ->
            console.log("sagews_hint")
            cur   = editor.getCursor()
            token = editor.getTokenAt(cur)
            console.log(token)
            t = token.string
            completions = (a for a in s when a.slice(0,t.length) == t)
            ans =
                list : completions,
                from : CodeMirror.Pos(cur.line, token.start)
                to   : CodeMirror.Pos(cur.line, token.end)
        CodeMirror.registerHelper("hint", "sagews", sagews_hint)
    ###


# Given a text file (defined by content), try to guess
# what the extension should be.
guess_file_extension_type = (content) ->
    content = $.trim(content)
    i = content.indexOf('\n')
    first_line = content.slice(0,i).toLowerCase()
    if first_line.slice(0,2) == '#!'
        # A script.  What kind?
        if first_line.indexOf('python') != -1
            return 'py'
        if first_line.indexOf('bash') != -1 or first_line.indexOf('sh') != -1
            return 'sh'
    if first_line.indexOf('html') != -1
        return 'html'
    if first_line.indexOf('/*') != -1 or first_line.indexOf('//') != -1   # kind of a stretch
        return 'c++'
    return undefined

SEP = "\uFE10"

_local_storage_prefix = (project_id, filename, key) ->
    s = project_id
    if filename?
        s += filename + SEP
    if key?
        s += key
    return s
#
# Set or get something about a project from local storage:
#
#    local_storage(project_id):  returns everything known about this project.
#    local_storage(project_id, filename):  get everything about given filename in project
#    local_storage(project_id, filename, key):  get value of key for given filename in project
#    local_storage(project_id, filename, key, value):   set value of key
#
# In all cases, returns undefined if localStorage is not supported in this browser.
#

local_storage_delete = exports.local_storage_delete = (project_id, filename, key) ->
    storage = window.localStorage
    if storage?
        prefix = _local_storage_prefix(project_id, filename, key)
        n = prefix.length
        for k, v of storage
            if k.slice(0,n) == prefix
                delete storage[k]

local_storage = exports.local_storage = (project_id, filename, key, value) ->
    storage = window.localStorage
    if storage?
        prefix = _local_storage_prefix(project_id, filename, key)
        n = prefix.length
        if filename?
            if key?
                if value?
                    storage[prefix] = misc.to_json(value)
                else
                    x = storage[prefix]
                    if not x?
                        return x
                    else
                        return misc.from_json(x)
            else
                # Everything about a given filename
                obj = {}
                for k, v of storage
                    if k.slice(0,n) == prefix
                        obj[k.split(SEP)[1]] = v
                return obj
        else
            # Everything about project
            obj = {}
            for k, v of storage
                if k.slice(0,n) == prefix
                    x = k.slice(n)
                    z = x.split(SEP)
                    filename = z[0]
                    key = z[1]
                    if not obj[filename]?
                        obj[filename] = {}
                    obj[filename][key] = v
            return obj

templates = $("#salvus-editor-templates")

class exports.Editor
    constructor: (opts) ->
        opts = defaults opts,
            project_page  : required
            initial_files : undefined # if given, attempt to open these files on creation
            counter       : undefined # if given, is a jQuery set of DOM objs to set to the number of open files
        @counter = opts.counter
        @project_page  = opts.project_page
        @project_path = opts.project_page.project.location?.path
        if not @project_path
            @project_path = '.'  # if location isn't defined yet -- and this is the only thing used anyways.
        @project_id = opts.project_page.project.project_id
        @element = templates.find(".salvus-editor").clone().show()

        # read-only public access to project only
        @public_access = opts.project_page.public_access

        @nav_tabs = @element.find(".nav-pills")

        @tabs = {}   # filename:{useful stuff}

        @init_openfile_search()

        if opts.initial_files?
            for filename in opts.initial_files
                @open(filename)

    activate_handlers: () =>
        #console.log "activate_handlers - #{@project_id}"
        $(document).keyup(@keyup_handler)
        $(window).resize(@_window_resize_while_editing)

    remove_handlers: () =>
        #console.log "remove_handlers - #{@project_id}"
        $(document).unbind 'keyup', @keyup_handler
        $(window).unbind 'resize', @_window_resize_while_editing

    close_all_open_files: () =>
        for filename, tab of @tabs
            tab.close_editor()

    destroy: () =>
        @remove_handlers()
        @close_all_open_files()

    keyup_handler: (ev) =>
        #console.log("keyup handler for -- #{@project_id}", ev)
        if (ev.metaKey or ev.ctrlKey) and ev.keyCode == 79
            #console.log("editor keyup")
            @project_page.display_tab("project-file-listing")
            return false
        else if ev.ctrlKey
            #console.log("mod ", ev.keyCode)
            if ev.keyCode == 219    # [{
                @switch_tab(-1)
            else if ev.keyCode == 221   # }]
                @switch_tab(1)
            return false

    switch_tab: (delta) =>
        #console.log("switch_tab", delta)
        pgs = @project_page.container.find(".file-pages")
        idx = pgs.find(".active").index()
        if idx == -1 # nothing active
            return
        e = pgs.children()
        n = (idx + delta) % e.length
        if n < 0
            n += e.length
        path = $(e[n]).data('name')
        if path
            @display_tab
                path : path

    activity_indicator: (filename) =>
        e = @tabs[filename]?.open_file_pill
        if not e?
            return
        if not @_activity_indicator_timers?
            @_activity_indicator_timers = {}
        timer = @_activity_indicator_timers[filename]
        if timer?
            clearTimeout(timer)
        e.find("i:last").addClass("salvus-editor-filename-pill-icon-active")
        f = () ->
            e.find("i:last").removeClass("salvus-editor-filename-pill-icon-active")
        @_activity_indicator_timers[filename] = setTimeout(f, 1000)

        @project_page.activity_indicator()

    hide_editor_content: () =>
        @_editor_content_visible = false
        @element.find(".salvus-editor-content").hide()

    show_editor_content: () =>
        @_editor_content_visible = true
        @element.find(".salvus-editor-content").show()
        # temporary / ugly
        for tab in @project_page.tabs
            tab.label.removeClass('active')

        @project_page.container.css('position', 'fixed')

    # Used for resizing editor windows.
    editor_top_position: () =>
        if salvus_client.in_fullscreen_mode()
            return 0
        else
            e = @project_page.container
            return e.position().top + e.height()

    refresh: () =>
        @_window_resize_while_editing()

    _window_resize_while_editing: () =>
        #console.log("_window_resize_while_editing -- #{@project_id}")
        @resize_open_file_tabs()
        if not @active_tab? or not @_editor_content_visible
            return
        @active_tab.editor().show()

    init_openfile_search: () =>
        search_box = @element.find(".salvus-editor-search-openfiles-input")
        include = 'active' #salvus-editor-openfile-included-in-search'
        exclude = 'salvus-editor-openfile-excluded-from-search'
        search_box.focus () =>
            search_box.select()

        update = (event) =>
            @active_tab?.editor().hide()

            if event?
                if (event.metaKey or event.ctrlKey) and event.keyCode == 79     # control-o
                    #console.log("keyup: openfile_search")
                    @project_page.display_tab("project-new-file")
                    return false

                if event.keyCode == 27  and @active_tab? # escape - open last viewed tab
                    @display_tab(path:@active_tab.filename)
                    return

            v = $.trim(search_box.val()).toLowerCase()
            if v == ""
                for filename, tab of @tabs
                    tab.link.removeClass(include)
                    tab.link.removeClass(exclude)
                match = (s) -> true
            else
                terms = v.split(' ')
                match = (s) ->
                    s = s.toLowerCase()
                    for t in terms
                        if s.indexOf(t) == -1
                            return false
                    return true

            first = true

            for link in @nav_tabs.children()
                tab = $(link).data('tab')
                filename = tab.filename
                if match(filename)
                    if first and event?.keyCode == 13 # enter -- select first match (if any)
                        @display_tab(path:filename)
                        first = false
                    if v != ""
                        tab.link.addClass(include); tab.link.removeClass(exclude)
                else
                    if v != ""
                        tab.link.addClass(exclude); tab.link.removeClass(include)

        @element.find(".salvus-editor-search-openfiles-input-clear").click () =>
            search_box.val('')
            update()
            search_box.select()
            return false

        search_box.keyup(update)

    update_counter: () =>
        if @counter?
            @counter.text(len(@tabs))

    open: (filename, cb) =>   # cb(err, actual_opened_filename)
        if not filename?
            cb?("BUG -- open(undefined) makes no sense")
            return

        if @tabs[filename]?
            cb?(false, filename)
            return

        if @public_access
            binary = @file_options(filename).binary
        else
            # following only makes sense for read-write project access
            ext = filename_extension(filename).toLowerCase()

            if filename == ".sagemathcloud.log"
                cb?("You can only edit '.sagemathcloud.log' via the terminal.")
                return

            if ext == "sws"   # sagenb worksheet
                alert_message(type:"info",message:"Opening converted SageMathCloud worksheet file instead of '#{filename}...")
                @convert_sagenb_worksheet filename, (err, sagews_filename) =>
                    if not err
                        @open(sagews_filename, cb)
                    else
                        cb?("Error converting Sage Notebook sws file -- #{err}")
                return

            if ext == "docx"   # Microsoft Word Document
                alert_message(type:"info", message:"Opening converted plain text file instead of '#{filename}...")
                @convert_docx_file filename, (err, new_filename) =>
                    if not err
                        @open(new_filename, cb)
                    else
                        cb?("Error converting Microsoft docx file -- #{err}")
                return

        content = undefined
        extra_opts = {}
        async.series([
            (c) =>
                if @public_access and not binary
                    salvus_client.public_get_text_file
                        project_id : @project_id
                        path       : filename
                        timeout    : 60
                        cb         : (err, data) =>
                            if err
                                c(err)
                            else
                                content = data
                                extra_opts.read_only = true
                                extra_opts.public_access = true
                                # TODO: Allowing arbitrary javascript eval is dangerous
                                # for public documents, so we disable it, at least
                                # until we implement an option for loading in an iframe.
                                extra_opts.allow_javascript_eval = false
                                c()
                else
                    c()
        ], (err) =>
            if err
                cb?(err)
            else
                @tabs[filename] = @create_tab
                    filename   : filename
                    content    : content
                    extra_opts : extra_opts
                cb?(false, filename)
        )


    convert_sagenb_worksheet: (filename, cb) =>
        salvus_client.exec
            project_id : @project_id
            command    : "sws2sagews.py"
            args       : [filename]
            cb         : (err, output) =>
                if err
                    cb("#{err}, #{misc.to_json(output)}")
                else
                    cb(false, filename.slice(0,filename.length-3) + 'sagews')

    convert_docx_file: (filename, cb) =>
        salvus_client.exec
            project_id : @project_id
            command    : "docx2txt.py"
            args       : [filename]
            cb         : (err, output) =>
                if err
                    cb("#{err}, #{misc.to_json(output)}")
                else
                    cb(false, filename.slice(0,filename.length-4) + 'txt')

    file_options: (filename, content) =>   # content may be undefined
        ext = filename_extension(filename)?.toLowerCase()
        if not ext? and content?   # no recognized extension, but have contents
            ext = guess_file_extension_type(content)
        x = file_associations[ext]
        if not x?
            x = file_associations['']
        return x

    create_tab: (opts) =>
        opts = defaults opts,
            filename     : required
            content      : undefined
            extra_opts   : undefined

        filename = opts.filename
        if @tabs[filename]?
            return @tabs[filename]

        content = opts.content
        opts0 = @file_options(filename, content)
        extra_opts = copy(opts0.opts)

        if opts.extra_opts?
            for k, v of opts.extra_opts
                extra_opts[k] = v

        link = templates.find(".salvus-editor-filename-pill").clone().show()
        link_filename = link.find(".salvus-editor-tab-filename")
        link_filename.text(trunc(filename,64))

        containing_path = misc.path_split(filename).head
        ignore_clicks = false
        link.find("a").mousedown (e) =>
            if ignore_clicks
                return false
            foreground = not(e.which==2 or e.ctrlKey)
            @display_tab
                path       : link_filename.text()
                foreground : not(e.which==2 or (e.ctrlKey or e.metaKey))
            if foreground
                @project_page.set_current_path(containing_path)
            return false

        create_editor_opts =
            editor_name : opts0.editor
            filename    : filename
            content     : content
            extra_opts  : extra_opts

        editor = undefined
        @tabs[filename] =
            link     : link
            filename : filename

            editor   : () =>
                if editor?
                    return editor
                else
                    editor = @create_editor(create_editor_opts)
                    @element.find(".salvus-editor-content").append(editor.element.hide())
                    return editor

            hide_editor : () -> editor?.hide()

            editor_open : () -> editor?   # editor is defined if the editor is open.

            close_editor: () ->
                if editor?
                    editor.disconnect_from_session()
                    editor.remove()

                editor = undefined
                # We do *NOT* want to recreate the editor next time it is opened with the *same* options, or we
                # will end up overwriting it with stale contents.
                delete create_editor_opts.content


        link.data('tab', @tabs[filename])
        @nav_tabs.append(link)

        @update_counter()
        return @tabs[filename]

    create_editor: (opts) =>
        {editor_name, filename, content, extra_opts} = defaults opts,
            editor_name : required
            filename    : required
            content     : undefined
            extra_opts  : required

        #console.log("create_editor", opts)

        if editor_name == 'codemirror'
            if filename.slice(filename.length-7) == '.sagews'
                typ = 'worksheet'  # TODO: only because we don't use Worksheet below anymore
            else
                typ = 'file'
        else
            typ = editor_name
        @project_page.project_activity({event:'open', filename:filename, type:typ})

        # This approach to public "editor"/viewer types is temporary.
        if extra_opts.public_access
            if filename_extension(filename) == 'html'
                if opts.content.indexOf("#ipython_notebook") != -1
                    editor = new IPythonNBViewer(@, filename, opts.content, extra_opts)
                else
                    editor = new StaticHTML(@, filename, opts.content, extra_opts)
                return editor

        # Some of the editors below might get the content later and will
        # call @file_options again then.
        switch editor_name
            # TODO: JSON, since I have that jsoneditor plugin...
            # codemirror is the default...
            when 'codemirror', undefined
                if extra_opts.public_access
                    # This is used only for public access to files
                    console.log("opts.content='#{opts.content}'")
                    editor = new CodeMirrorEditor(@, filename, opts.content, extra_opts)
                    if filename_extension(filename) == 'sagews'
                        editor.syncdoc = new (syncdoc.SynchronizedWorksheet)(editor, {static_viewer:true})
                        editor.once 'show', () =>
                            console.log("process_sage_updates")
                            editor.syncdoc.process_sage_updates()
                else
                    # realtime synchronized editing session
                    editor = codemirror_session_editor(@, filename, extra_opts)
            when 'terminal'
                editor = new Terminal(@, filename, content, extra_opts)
            when 'image'
                editor = new Image(@, filename, content, extra_opts)
            when 'latex'
                editor = new LatexEditor(@, filename, content, extra_opts)
            when 'html-md'
                if extra_opts.public_access
                    editor = new CodeMirrorEditor(@, filename, opts.content, extra_opts)
                else
                    editor = new HTML_MD_Editor(@, filename, content, extra_opts)
            when 'history'
                editor = new HistoryEditor(@, filename, content, extra_opts)
            when 'pdf'
                editor = new PDF_PreviewEmbed(@, filename, content, extra_opts)
            when 'tasks'
                editor = new TaskList(@, filename, content, extra_opts)
            when 'course'
                editor = new Course(@, filename, content, extra_opts)
            when 'ipynb'
                editor = new IPythonNotebook(@, filename, content, extra_opts)
            else
                throw("Unknown editor type '#{editor_name}'")

        return editor

    create_opened_file_tab: (filename) =>
        link_bar = @project_page.container.find(".file-pages")

        link = templates.find(".salvus-editor-filename-pill").clone()
        link.tooltip(title:filename, placement:'bottom', delay:{show: 500, hide: 0})

        link.data('name', filename)

        link_filename = link.find(".salvus-editor-tab-filename")
        display_name = path_split(filename).tail
        link_filename.text(display_name)

        # Add an icon to the file tab based on the extension. Default icon is fa-file-o
        ext = filename_extension(filename)
        file_icon = file_icon_class(ext)
        link_filename.prepend("<i class='fa #{file_icon}' style='font-size:10pt'> </i> ")

        open_file = (name) =>
            @project_page.set_current_path(misc.path_split(name).head)
            @project_page.display_tab("project-editor")
            @display_tab(path:name)

        close_tab = () =>
            if ignore_clicks
                return false

            if @active_tab? and @active_tab.filename == filename
                @active_tab = undefined

            if @project_page.current_tab.name == 'project-editor' and not @active_tab?
                next = link.next()
                # skip past div's inserted by tooltips
                while next.is("div")
                    next = next.next()
                name = next.data('name')  # need li selector because tooltip inserts itself after in DOM
                if name?
                    open_file(name)

            link.tooltip('destroy')
            link.hide()
            link.remove()

            if @project_page.current_tab.name == 'project-editor' and not @active_tab?
                # open last file if there is one
                next_link = link_bar.find("li").last()
                name = next_link.data('name')
                if name?
                    @resize_open_file_tabs()
                    open_file(name)
                else
                    # just show the file listing
                    @project_page.display_tab('project-file-listing')

            tab = @tabs[filename]
            if tab?
                if tab.open_file_pill?
                    delete tab.open_file_pill
                tab.editor()?.disconnect_from_session()
                tab.close_editor()
                delete @tabs[filename]

            @_currently_closing_files = true
            if @open_file_tabs().length < 1
                @resize_open_file_tabs()

            return false

        link.find(".salvus-editor-close-button-x").click(close_tab)

        ignore_clicks = false
        link.find("a").click (e) =>
            if ignore_clicks
                return false
            open_file(filename)
            return false

        link.find("a").mousedown (e) =>
            if ignore_clicks
                return false
            if e.which==2 or e.ctrlKey
                # middle (or control-) click on open tab: close the editor
                close_tab()
                return false


        #link.draggable
        #    zIndex      : 1000
        #    containment : "parent"
        #    stop        : () =>
        #        ignore_clicks = true
        #        setTimeout( (() -> ignore_clicks=false), 100)

        @tabs[filename].open_file_pill = link
        @tabs[filename].close_tab = close_tab

        link_bar.mouseleave () =>
            if @_currently_closing_files
                @_currently_closing_files = false
                @resize_open_file_tabs()

        link_bar.append(link)
        @resize_open_file_tabs()

    open_file_tabs: () =>
        x = []
        for a in @project_page.container.find(".file-pages").children()
            t = $(a)
            if t.hasClass("salvus-editor-filename-pill")
                x.push(t)
        return x

    hide: () =>
        for filename, tab of @tabs
            if tab?
                if tab.editor_open()
                    tab.editor().hide?()

    resize_open_file_tabs: () =>
        # First hide/show labels on the project navigation buttons (Files, New, Log..)
        if @open_file_tabs().length > require('editor').SHOW_BUTTON_LABELS
            @project_page.container.find(".project-pages-button-label").hide()
        else
            @project_page.container.find(".project-pages-button-label").show()

        # Make a list of the tabs after the search tab.
        x = @open_file_tabs()
        if x.length == 0
            return

        if misc_page.is_responsive_mode()
            # responsive mode
            @project_page.destroy_sortable_file_list()
            width = "50%"
        else
            @project_page.init_sortable_file_list()
            n = x.length
            width = Math.min(250, parseInt((x[0].parent().width() - 25) / n + 2)) # floor to prevent rounding problems
            if width < 0
                width = 0

        for a in x
            a.width(width)

    make_open_file_pill_active: (link) =>
        @project_page.container.find(".file-pages").children().removeClass('active')
        link.addClass('active')

    # Close tab with given filename
    close: (filename) =>
        tab = @tabs[filename]
        if not tab? # nothing to do -- tab isn't opened anymore
            return

        # Disconnect from remote session (if relevant)
        if tab.editor_open()
            tab.editor().disconnect_from_session()
            tab.editor().remove()

        tab.link.remove()
        tab.close_tab?()
        delete @tabs[filename]
        @update_counter()

    show_chat_window: (path) =>
        @tabs[path]?.editor()?.show_chat_window()

    # Reload content of this tab.  Warn user if this will result in changes.
    reload: (filename) =>
        tab = @tabs[filename]
        if not tab? # nothing to do
            return
        salvus_client.read_text_file_from_project
            project_id : @project_id
            timeout    : 5
            path       : filename
            cb         : (err, mesg) =>
                if err
                    alert_message(type:"error", message:"Communications issue loading new version of #{filename} -- #{err}")
                else if mesg.event == 'error'
                    alert_message(type:"error", message:"Error loading new version of #{filename} -- #{to_json(mesg.error)}")
                else
                    current_content = tab.editor().val()
                    new_content = mesg.content
                    if current_content != new_content
                        @warn_user filename, (proceed) =>
                            if proceed
                                tab.editor().val(new_content)

    # Warn user about unsaved changes (modal)
    warn_user: (filename, cb) =>
        cb(true)

    # Make the tab appear in the tabs at the top, and
    # if foreground=true, also make that tab active.
    display_tab: (opts) =>
        opts = defaults opts,
            path       : required
            foreground : true      # display in foreground as soon as possible
        filename = opts.path
        if not @tabs[filename]?
            return

        if opts.foreground
            @_active_tab_filename = filename
            @push_state('files/' + opts.path)
            @show_editor_content()

        prev_active_tab = @active_tab
        for name, tab of @tabs
            if name == filename
                if not tab.open_file_pill?
                    @create_opened_file_tab(filename)

                if opts.foreground
                    # make sure that there is a tab and show it if necessary, and also
                    # set it to the active tab (if necessary).
                    @active_tab = tab
                    @make_open_file_pill_active(tab.open_file_pill)
                    ed = tab.editor()
                    ed.show()
                    ed.focus()

            else if opts.foreground
                # ensure all other tabs are hidden.
                tab.hide_editor()

        @project_page.init_sortable_file_list()

    add_tab_to_navbar: (filename) =>
        navbar = require('top_navbar').top_navbar
        tab = @tabs[filename]
        if not tab?
            return
        id = @project_id + filename
        if not navbar.pages[id]?
            navbar.add_page
                id     : id
                label  : misc.path_split(filename).tail
                onshow : () =>
                    navbar.switch_to_page(@project_id)
                    @display_tab(path:filename)
                    navbar.make_button_active(id)

    onshow: () =>  # should be called when the editor is shown.
        #if @active_tab?
        #    @display_tab(@active_tab.filename)
        if not IS_MOBILE
            @element.find(".salvus-editor-search-openfiles-input").focus()

    push_state: (url) =>
        if not url?
            url = @_last_history_state
        if not url?
            url = 'recent'
        @_last_history_state = url
        @project_page.push_state(url)

    # Save the file to disk/repo
    save: (filename, cb) =>       # cb(err)
        if not filename?  # if filename not given, save all *open* files
            tasks = []
            for filename, tab of @tabs
                if tab.editor_open()
                    f = (c) =>
                        @save(arguments.callee.filename, c)
                    f.filename = filename
                    tasks.push(f)
            async.parallel(tasks, cb)
            return

        tab = @tabs[filename]
        if not tab?
            cb?()
            return

        if not tab.editor().has_unsaved_changes()
            # nothing to save
            cb?()
            return

        tab.editor().save(cb)

    change_tab_filename: (old_filename, new_filename) =>
        tab = @tabs[old_filename]
        if not tab?
            # TODO -- fail silently or this?
            alert_message(type:"error", message:"change_tab_filename (bug): attempt to change #{old_filename} to #{new_filename}, but there is no tab #{old_filename}")
            return
        tab.filename = new_filename
        tab.link.find(".salvus-editor-tab-filename").text(new_filename)
        delete @tabs[old_filename]
        @tabs[new_filename] = tab


###############################################
# Abstract base class for editors
###############################################
# Derived classes must:
#    (1) implement the _get and _set methods
#    (2) show/hide/remove
#
# Events ensure that *all* users editor the same file see the same
# thing (synchronized).
#

class FileEditor extends EventEmitter
    constructor: (@editor, @filename, content, opts) ->
        @val(content)

    activity_indicator: () =>
        @editor?.activity_indicator(@filename)

    show_chat_window: () =>
        @syncdoc?.show_chat_window()

    is_active: () =>
        return @editor._active_tab_filename == @filename

    init_file_actions: (element) =>
        if not element
            element = @element
        copy_btn     = element.find("a[href=#copy-to-another-project]")
        #download_btn = element.find("a[href=#download-file]")
        info_btn     = element.find("a[href=#file-info]")
        project = @editor.project_page
        if project.public_access
            copy_btn.click () =>
                project.copy_to_another_project_dialog(@filename, false)
                return false
            #download_btn.click () =>
            #    project.download_file
            #        path : @filename
            #    return false
            info_btn.hide()
        else
            copy_btn.hide()
            #download_btn.hide()
            info_btn.click () =>
                project.file_action_dialog
                    fullname : @filename
                    isdir    : false
                    url      : document.URL

    init_autosave: () =>
        if @_autosave_interval?
            # This function can safely be called again to *adjust* the
            # autosave interval, in case user changes the settings.
            clearInterval(@_autosave_interval)

        # Use the most recent autosave value.
        autosave = require('account').account_settings.settings.autosave
        if autosave
            save_if_changed = () =>
                if not @editor.tabs[@filename]?.editor_open()
                    # don't autosave anymore if the doc is closed -- since autosave references
                    # the editor, which would re-create it, causing the tab to reappear.  Not pretty.
                    clearInterval(@_autosave_interval)
                    return
                if @has_unsaved_changes()
                    if @click_save_button?
                        # nice gui feedback
                        @click_save_button()
                    else
                        @save()
            @_autosave_interval = setInterval(save_if_changed, autosave * 1000)

    val: (content) =>
        if not content?
            # If content not defined, returns current value.
            return @_get()
        else
            # If content is defined, sets value.
            @_set(content)

    # has_unsaved_changes() returns the state, where true means that
    # there are unsaved changed.  To set the state, do
    # has_unsaved_changes(true or false).
    has_unsaved_changes: (val) =>
        if not val?
            return @_has_unsaved_changes
        else
            if not @_has_unsaved_changes? or @_has_unsaved_changes != val
                if val
                    @save_button.removeClass('disabled')
                else
                    @save_button.addClass('disabled')
            @_has_unsaved_changes = val

    focus: () => # TODO in derived class

    _get: () =>
        throw("TODO: implement _get in derived class")

    _set: (content) =>
        throw("TODO: implement _set in derived class")

    restore_cursor_position: () =>
        # implement in a derived class if you need this

    disconnect_from_session: (cb) =>
        # implement in a derived class if you need this

    local_storage: (key, value) =>
        return local_storage(@editor.project_id, @filename, key, value)

    show: (opts) =>
        if not opts?
            if @_last_show_opts?
                opts = @_last_show_opts
            else
                opts = {}
        @_last_show_opts = opts
        if not @is_active()
            return

        # Show gets called repeatedly as we resize the window, so we wait until slightly *after*
        # the last call before doing the show.
        now = misc.mswalltime()
        if @_last_call? and now - @_last_call < 500
            if not @_show_timer?
                @_show_timer = setTimeout((()=>delete @_show_timer; @show(opts)), now - @_last_call)
            return
        @_last_call = now
        @element.show()
        @_show(opts)

    _show: (opts={}) =>
        # define in derived class

    hide: () =>
        @element.hide()

    remove: () =>
        @element.remove()

    terminate_session: () =>
        # If some backend session on a remote machine is serving this session, terminate it.

    save: (cb) =>
        content = @val()
        if not content?
            # do not overwrite file in case editor isn't initialized
            alert_message(type:"error", message:"Editor of '#{filename}' not initialized, so nothing to save.")
            cb?()
            return

        salvus_client.write_text_file_to_project
            project_id : @editor.project_id
            timeout    : 10
            path       : @filename
            content    : content
            cb         : (err, mesg) =>
                # TODO -- on error, we *might* consider saving to localStorage...
                if err
                    alert_message(type:"error", message:"Communications issue saving #{filename} -- #{err}")
                    cb?(err)
                else if mesg.event == 'error'
                    alert_message(type:"error", message:"Error saving #{filename} -- #{to_json(mesg.error)}")
                    cb?(mesg.error)
                else
                    cb?()

###############################################
# Codemirror-based File Editor
###############################################
class CodeMirrorEditor extends FileEditor
    constructor: (@editor, @filename, content, opts) ->
        editor_settings = require('account').account_settings.settings.editor_settings

        opts = @opts = defaults opts,
            mode                      : required
            geometry                  : undefined  # (default=full screen);
            read_only                 : false
            delete_trailing_whitespace: editor_settings.strip_trailing_whitespace  # delete on save
            show_trailing_whitespace  : editor_settings.show_trailing_whitespace
            allow_javascript_eval     : true  # if false, the one use of eval isn't allowed.
            line_numbers              : editor_settings.line_numbers
            first_line_number         : editor_settings.first_line_number
            indent_unit               : editor_settings.indent_unit
            tab_size                  : editor_settings.tab_size
            smart_indent              : editor_settings.smart_indent
            electric_chars            : editor_settings.electric_chars
            undo_depth                : editor_settings.undo_depth
            match_brackets            : editor_settings.match_brackets
            code_folding              : editor_settings.code_folding
            auto_close_brackets       : editor_settings.auto_close_brackets
            match_xml_tags            : editor_settings.match_xml_tags
            auto_close_xml_tags       : editor_settings.auto_close_xml_tags
            line_wrapping             : editor_settings.line_wrapping
            spaces_instead_of_tabs    : editor_settings.spaces_instead_of_tabs
            style_active_line         : 15    # editor_settings.style_active_line  # (a number between 0 and 127)
            bindings                  : editor_settings.bindings  # 'standard', 'vim', or 'emacs'
            theme                     : editor_settings.theme
            track_revisions           : editor_settings.track_revisions
            public_access             : false

            # I'm making the times below very small for now.  If we have to adjust these to reduce load, due to lack
            # of capacity, then we will.  Or, due to lack of optimization (e.g., for big documents). These parameters
            # below would break editing a huge file right now, due to slowness of applying a patch to a codemirror editor.

            cursor_interval           : 1000   # minimum time (in ms) between sending cursor position info to hub -- used in sync version
            sync_interval             : 750    # minimum time (in ms) between synchronizing text with hub. -- used in sync version below

            completions_size          : 20    # for tab completions (when applicable, e.g., for sage sessions)

        #console.log("mode =", opts.mode)

        @project_id = @editor.project_id
        @element = templates.find(".salvus-editor-codemirror").clone()

        @element.data('editor', @)

        @init_file_actions()

        @init_save_button()
        @init_history_button()
        @init_edit_buttons()

        @init_close_button()
        filename = @filename
        if filename.length > 30
            filename = "…" + filename.slice(filename.length-30)

        # not really needed due to highlighted tab; annoying.
        #@element.find(".salvus-editor-codemirror-filename").text(filename)

        @_chat_is_hidden = @local_storage("chat_is_hidden")
        if not @_chat_is_hidden?
            @_chat_is_hidden = true

        @_layout = @local_storage("layout")
        if not @_layout?
            @_layout = 1
        @_last_layout = @_layout

        layout_elt = @element.find(".salvus-editor-codemirror-input-container-layout-#{@_layout}").show()
        elt = layout_elt.find(".salvus-editor-codemirror-input-box").find("textarea")
        elt.text(content)

        extraKeys =
            "Alt-Enter"    : (editor)   => @action_key(execute: true, advance:false, split:false)
            "Cmd-Enter"    : (editor)   => @action_key(execute: true, advance:false, split:false)
            "Ctrl-Enter"   : (editor)   => @action_key(execute: true, advance:true, split:true)
            "Ctrl-;"       : (editor)   => @action_key(split:true, execute:false, advance:false)
            "Cmd-;"        : (editor)   => @action_key(split:true, execute:false, advance:false)
            "Ctrl-\\"      : (editor)   => @action_key(execute:false, toggle_input:true)
            #"Cmd-x"  : (editor)   => @action_key(execute:false, toggle_input:true)
            "Shift-Ctrl-\\" : (editor)   => @action_key(execute:false, toggle_output:true)
            #"Shift-Cmd-y"  : (editor)   => @action_key(execute:false, toggle_output:true)

            "Ctrl-S"       : (editor)   => @click_save_button()
            "Cmd-S"        : (editor)   => @click_save_button()

            "Ctrl-L"       : (editor)   => @goto_line(editor)
            "Cmd-L"        : (editor)   => @goto_line(editor)

            "Ctrl-I"       : (editor)   => @toggle_split_view(editor)
            "Cmd-I"        : (editor)   => @toggle_split_view(editor)

            "Shift-Ctrl-." : (editor)   => @change_font_size(editor, +1)
            "Shift-Ctrl-," : (editor)   => @change_font_size(editor, -1)
            "Shift-Cmd-."  : (editor)   => @change_font_size(editor, +1)
            "Shift-Cmd-,"  : (editor)   => @change_font_size(editor, -1)

            "Shift-Tab"    : (editor)   => editor.unindent_selection()

            "Ctrl-'"       : "indentAuto"

            "Tab"          : (editor)   => @press_tab_key(editor)
            "Shift-Ctrl-C" : (editor)   => @interrupt_key()

            "Enter"        : @enter_key
            "Ctrl-Space"   : "autocomplete"

            #"F11"          : (editor)   => console.log('fs', editor.getOption("fullScreen")); editor.setOption("fullScreen", not editor.getOption("fullScreen"))

        if opts.match_xml_tags
            extraKeys['Ctrl-J'] = "toMatchingTag"

        # We will replace this by a general framework...
        if misc.filename_extension(filename) == "sagews"
            evaluate_key = require('account').account_settings.settings.evaluate_key.toLowerCase()
            if evaluate_key == "enter"
                evaluate_key = "Enter"
            else
                evaluate_key = "Shift-Enter"
            extraKeys[evaluate_key] = (editor)   => @action_key(execute: true, advance:true, split:false)

        make_editor = (node) =>
            options =
                firstLineNumber         : opts.first_line_number
                autofocus               : false
                mode                    : {name:opts.mode, globalVars: true}
                lineNumbers             : opts.line_numbers
                showTrailingSpace       : opts.show_trailing_whitespace
                indentUnit              : opts.indent_unit
                tabSize                 : opts.tab_size
                smartIndent             : opts.smart_indent
                electricChars           : opts.electric_chars
                undoDepth               : opts.undo_depth
                matchBrackets           : opts.match_brackets
                autoCloseBrackets       : opts.auto_close_brackets
                autoCloseTags           : opts.auto_close_xml_tags
                lineWrapping            : opts.line_wrapping
                readOnly                : opts.read_only
                styleActiveLine         : opts.style_active_line
                indentWithTabs          : not opts.spaces_instead_of_tabs
                showCursorWhenSelecting : true
                extraKeys               : extraKeys
                cursorScrollMargin      : 40

            if opts.match_xml_tags
                options.matchTags = {bothTags: true}

            if opts.code_folding
                 extraKeys["Ctrl-Q"] = (cm) -> cm.foldCodeSelectionAware()
                 options.foldGutter  = true
                 options.gutters     = ["CodeMirror-linenumbers", "CodeMirror-foldgutter"]

            if opts.bindings? and opts.bindings != "standard"
                options.keyMap = opts.bindings
                #cursorBlinkRate: 1000

            if opts.theme? and opts.theme != "standard"
                options.theme = opts.theme

            cm = CodeMirror.fromTextArea(node, options)
            cm.save = () => @click_save_button()

            # The Codemirror themes impose their own weird fonts, but most users want whatever
            # they've configured as "monospace" in their browser.  So we force that back:
            e = $(cm.getWrapperElement())
            e.attr('style', e.attr('style') + '; font-family:monospace !important')  # see http://stackoverflow.com/questions/2655925/apply-important-css-style-using-jquery

            if opts.bindings == 'vim'
                # annoying due to api change in vim mode
                cm.setOption("vimMode", true)

            return cm


        @codemirror = make_editor(elt[0])
        @codemirror.name = '0'

        elt1 = layout_elt.find(".salvus-editor-codemirror-input-box-1").find("textarea")

        @codemirror1 = make_editor(elt1[0])
        @codemirror1.name = '1'

        buf = @codemirror.linkedDoc({sharedHist: true})
        @codemirror1.swapDoc(buf)

        @codemirror.on 'focus', () =>
            @codemirror_with_last_focus = @codemirror

        @codemirror1.on 'focus', () =>
            @codemirror_with_last_focus = @codemirror1

        @restore_font_size()

        @_split_view = @local_storage("split_view")
        if not @_split_view?
            @_split_view = false


        @init_change_event()
        @init_draggable_splits()

        if opts.read_only
            @set_readonly_ui()

        if @filename.slice(@filename.length-7) == '.sagews'
            @init_sagews_edit_buttons()


    init_draggable_splits: () =>
        @_layout1_split_pos = @local_storage("layout1_split_pos")
        @_layout2_split_pos = @local_storage("layout2_split_pos")

        layout1_bar = @element.find(".salvus-editor-resize-bar-layout-1")
        layout1_bar.draggable
            axis        : 'y'
            containment : @element
            zIndex      : 100
            stop        : (event, ui) =>
                # compute the position of bar as a number from 0 to 1, with 0 being at top (left), 1 at bottom (right), and .5 right in the middle
                e   = @element.find(".salvus-editor-codemirror-input-container-layout-1")
                top = e.offset().top
                ht  = e.height()
                p   = layout1_bar.offset().top + layout1_bar.height()/2
                @_layout1_split_pos = (p - top) / ht
                @local_storage("layout1_split_pos", @_layout1_split_pos)
                layout1_bar.css(top:0)
                # redraw, which uses split info
                @show()

        layout2_bar = @element.find(".salvus-editor-resize-bar-layout-2")
        layout2_bar.css(position:'absolute')
        layout2_bar.draggable
            axis        : 'x'
            containment : @element
            zIndex      : 100
            stop        : (event, ui) =>
                # compute the position of bar as a number from 0 to 1, with 0 being at top (left), 1 at bottom (right), and .5 right in the middle
                e     = @element.find(".salvus-editor-codemirror-input-container-layout-2")
                left  = e.offset().left
                width = e.width()
                p     = layout2_bar.offset().left
                @_layout2_split_pos = (p - left) / width
                @local_storage("layout2_split_pos", @_layout2_split_pos)
                layout2_bar.css(left:left + width*p)
                # redraw, which uses split info
                @show()

    is_active: () =>
        return @codemirror? and @editor? and @editor._active_tab_filename == @filename

    set_theme: (theme) =>
        # Change the editor theme after the editor has been created
        @codemirror.setOption('theme', theme)
        @codemirror1.setOption('theme', theme)
        @opts.theme = theme

    # add something visual to the UI to suggest that the file is read only
    set_readonly_ui: () =>
        @element.find("a[href=#save]").text('Readonly').addClass('disabled')
        @element.find(".salvus-editor-write-only").hide()

    set_cursor_center_focus: (pos, tries=5) =>
        if tries <= 0
            return
        cm = @codemirror_with_last_focus
        if not cm?
            cm = @codemirror
        if not cm?
            return
        cm.setCursor(pos)
        info = cm.getScrollInfo()
        try
            # This call can fail during editor initialization (as of codemirror 3.19, but not before).
            cm.scrollIntoView(pos, info.clientHeight/2)
        catch e
            setTimeout((() => @set_cursor_center_focus(pos, tries-1)), 250)
        cm.focus()

    disconnect_from_session: (cb) =>
        # implement in a derived class if you need this
        @syncdoc?.disconnect_from_session()
        cb?()

    codemirrors: () =>
        return [@codemirror, @codemirror1]

    focused_codemirror: () =>
        if @codemirror_with_last_focus?
            return @codemirror_with_last_focus
        else
            return @codemirror

    action_key: (opts) =>
        # opts ignored by default; worksheets use them....
        @click_save_button()

    interrupt_key: () =>
        # does nothing for generic editor, but important, e.g., for the sage worksheet editor.

    enter_key: (editor) =>
        if @custom_enter_key?
            @custom_enter_key(editor)
        else
            return CodeMirror.Pass

    press_tab_key: (editor) =>
        if editor.somethingSelected()
            CodeMirror.commands.defaultTab(editor)
        else
            @tab_nothing_selected(editor)

    tab_nothing_selected: (editor) =>
        if @opts.spaces_instead_of_tabs
            editor.tab_as_space()
        else
            CodeMirror.commands.defaultTab(editor)

    init_edit_buttons: () =>
        that = @
        for name in ['search', 'next', 'prev', 'replace', 'undo', 'redo', 'autoindent',
                     'shift-left', 'shift-right', 'split-view','increase-font', 'decrease-font', 'goto-line', 'print' ]
            e = @element.find("a[href=##{name}]")
            e.data('name', name).tooltip(delay:{ show: 500, hide: 100 }).click (event) ->
                that.click_edit_button($(@).data('name'))
                return false

        # TODO: implement printing for other file types
        if @filename.slice(@filename.length-7) != '.sagews'
            @element.find("a[href=#print]").unbind().hide()

    click_edit_button: (name) =>
        cm = @codemirror_with_last_focus
        if not cm?
            cm = @codemirror
        if not cm?
            return
        switch name
            when 'search'
                CodeMirror.commands.find(cm)
            when 'next'
                if cm._searchState?.query
                    CodeMirror.commands.findNext(cm)
                else
                    CodeMirror.commands.goPageDown(cm)
            when 'prev'
                if cm._searchState?.query
                    CodeMirror.commands.findPrev(cm)
                else
                    CodeMirror.commands.goPageUp(cm)
            when 'replace'
                CodeMirror.commands.replace(cm)
            when 'undo'
                cm.undo()
            when 'redo'
                cm.redo()
            when 'split-view'
                @toggle_split_view(cm)
            when 'autoindent'
                CodeMirror.commands.indentAuto(cm)
            when 'shift-left'
                cm.unindent_selection()
            when 'shift-right'
                @press_tab_key(cm)
            when 'increase-font'
                @change_font_size(cm, +1)
            when 'decrease-font'
                @change_font_size(cm, -1)
            when 'goto-line'
                @goto_line(cm)
            when 'print'
                @print()

    restore_font_size: () =>
        for i, cm of [@codemirror, @codemirror1]
            size = @local_storage("font_size#{i}")
            if size?
                @set_font_size(cm, size)

    set_font_size: (cm, size) =>
        if size > 1
            elt = $(cm.getWrapperElement())
            elt.css('font-size', size + 'px')
            elt.data('font-size', size)

    change_font_size: (cm, delta) =>
        #console.log("change_font_size #{cm.name}, #{delta}")
        scroll_before = cm.getScrollInfo()

        elt = $(cm.getWrapperElement())
        size = elt.data('font-size')
        if not size?
            s = elt.css('font-size')
            size = parseInt(s.slice(0,s.length-2))
        new_size = size + delta
        @set_font_size(cm, new_size)
        @local_storage("font_size#{cm.name}", new_size)

        # we have to do the scrollTo in the next render loop, since otherwise
        # the getScrollInfo function below will return the sizing data about
        # the cm instance before the above css font-size change has been rendered.
        f = () =>
            cm.refresh()
            scroll_after = cm.getScrollInfo()
            x = (scroll_before.left / scroll_before.width) * scroll_after.width
            y = (((scroll_before.top+scroll_before.clientHeight/2) / scroll_before.height) * scroll_after.height) - scroll_after.clientHeight/2
            cm.scrollTo(x, y)
        setTimeout(f, 0)

    toggle_split_view: (cm) =>
        if @_split_view
            if @_layout == 1
                @_layout = 2
            else
                @_split_view = false
        else
            @_split_view = true
            @_layout = 1
        @local_storage("split_view", @_split_view)  # store state so can restore same on next open
        @local_storage("layout", @_layout)
        @show()
        @focus()
        cm.focus()

    goto_line: (cm) =>
        focus = () =>
            @focus()
            cm.focus()
        dialog = templates.find(".salvus-goto-line-dialog").clone()
        dialog.modal('show')
        dialog.find(".btn-close").off('click').click () ->
            dialog.modal('hide')
            setTimeout(focus, 50)
            return false
        input = dialog.find(".salvus-goto-line-input")
        input.val(cm.getCursor().line+1)  # +1 since line is 0-based
        dialog.find(".salvus-goto-line-range").text("1-#{cm.lineCount()} or n%")
        dialog.find(".salvus-goto-line-input").focus().select()
        submit = () =>
            dialog.modal('hide')
            result = input.val().trim()
            if result.length >= 1 and result[result.length-1] == '%'
                line = Math.floor( cm.lineCount() * parseInt(result.slice(0,result.length-1)) / 100.0)
            else
                line = Math.min(parseInt(result)-1)
            if line >= cm.lineCount()
                line = cm.lineCount() - 1
            if line <= 0
                line = 0
            pos = {line:line, ch:0}
            cm.setCursor(pos)
            info = cm.getScrollInfo()
            cm.scrollIntoView(pos, info.clientHeight/2)
            setTimeout(focus, 50)
        dialog.find(".btn-submit").off('click').click(submit)
        input.keydown (evt) =>
            if evt.which == 13 # enter
                submit()
                return false
            if evt.which == 27 # escape
                setTimeout(focus, 50)
                dialog.modal('hide')
                return false

    # TODO: this "print" is actually for printing Sage worksheets, not arbitrary files.
    print: () =>
        dialog = templates.find(".salvus-file-print-dialog").clone()
        p = misc.path_split(@filename)
        v = p.tail.split('.')
        if v.length <= 1
            ext = ''
            base = p.tail
        else
            ext = v[v.length-1]
            base = v.slice(0,v.length-1).join('.')
        if ext != 'sagews'
            alert_message(type:'info', message:'Only printing of Sage Worksheets is currently implemented.')
            return

        submit = () =>
            dialog.find(".salvus-file-printing-progress").show()
            dialog.find(".salvus-file-printing-link").hide()
            dialog.find(".btn-submit").icon_spin(start:true)
            pdf = undefined
            async.series([
                (cb) =>
                    @save(cb)
                (cb) =>
                    salvus_client.print_to_pdf
                        project_id  : @project_id
                        path        : @filename
                        options     :
                            title      : dialog.find(".salvus-file-print-title").text()
                            author     : dialog.find(".salvus-file-print-author").text()
                            date       : dialog.find(".salvus-file-print-date").text()
                            contents   : dialog.find(".salvus-file-print-contents").is(":checked")
                            extra_data : misc.to_json(@syncdoc.print_to_pdf_data())  # avoid de/re-json'ing
                        cb          : (err, _pdf) =>
                            if err
                                cb(err)
                            else
                                pdf = _pdf
                                cb()
                (cb) =>
                    salvus_client.read_file_from_project
                        project_id : @project_id
                        path       : pdf
                        cb         : (err, mesg) =>
                            if err
                                cb(err)
                            else
                                url = mesg.url + "?nocache=#{Math.random()}"
                                window.open(url,'_blank')
                                dialog.find(".salvus-file-printing-link").attr('href', url).text(pdf).show()
                                cb()
            ], (err) =>
                dialog.find(".btn-submit").icon_spin(false)
                dialog.find(".salvus-file-printing-progress").hide()
                if err
                    alert_message(type:"error", message:"problem printing '#{p.tail}' -- #{misc.to_json(err)}")
            )
            return false

        dialog.find(".salvus-file-print-filename").text(@filename)
        dialog.find(".salvus-file-print-title").text(base)
        dialog.find(".salvus-file-print-author").text(require('account').account_settings.fullname())
        dialog.find(".salvus-file-print-date").text((new Date()).toLocaleDateString())
        dialog.find(".btn-submit").click(submit)
        dialog.find(".btn-close").click(() -> dialog.modal('hide'); return false)
        if ext == "sagews"
            dialog.find(".salvus-file-options-sagews").show()
        dialog.modal('show')

    init_close_button: () =>
        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

    init_save_button: () =>
        @save_button = @element.find("a[href=#save]").tooltip().click(@click_save_button)
        @save_button.find(".spinner").hide()

    init_history_button: () =>
        if require('account').account_settings.settings.editor_settings.track_revisions and @filename.slice(@filename.length-13) != '.sage-history'
            @history_button = @element.find(".salvus-editor-history-button")
            @history_button.click(@click_history_button)
            @history_button.show()
            @history_button.css
                display: 'inline-block'   # this is needed due to subtleties of jQuery show().

    click_save_button: () =>
        if @_saving
            return
        @_saving = true
        @save_button.icon_spin(start:true, delay:1500)
        @editor.save @filename, (err) =>
            @save_button.icon_spin(false)
            @_saving = false
            @has_unsaved_changes(false)
        return false

    click_history_button: () =>
        p = misc.path_split(@filename)
        if p.head
            path = "#{p.head}/.#{p.tail}.sage-history"
        else
            path = ".#{p.tail}.sage-history"
        @editor.project_page.open_file
            path       : path
            foreground : true

    init_change_event: () =>
        @codemirror.on 'changes', () =>
            @has_unsaved_changes(true)

    _get: () =>
        return @codemirror.getValue()

    _set: (content) =>
        {from} = @codemirror.getViewport()
        @codemirror.setValue(content)
        @codemirror.scrollIntoView(from)
        # even better -- fully restore cursors, if available in localStorage
        setTimeout((()=>@restore_cursor_position()),1)  # do in next round, so that both editors get set by codemirror first (including the linked one)

    restore_cursor_position: () =>
        for i, cm of [@codemirror, @codemirror1]
            if cm?
                pos = @local_storage("cursor#{i}")
                if pos?
                    cm.setCursor(pos)
                    #console.log("#{@filename}: setting view #{cm.name} to cursor pos -- #{misc.to_json(pos)}")
                    info = cm.getScrollInfo()
                    try
                        cm.scrollIntoView(pos, info.clientHeight/2)
                    catch e
                        #console.log("#{@filename}: failed to scroll view #{cm.name} into view -- #{e}")


    # set background color of active line in editor based on background color (which depends on the theme)
    _style_active_line: () =>
        if not @opts.style_active_line
            return
        rgb = $(@codemirror.getWrapperElement()).css('background-color')
        v = (parseInt(x) for x in rgb.slice(4,rgb.length-1).split(','))
        amount = @opts.style_active_line
        for i in [0..2]
            if v[i] >= 128
                v[i] -= amount
            else
                v[i] += amount
        $("body").remove("#salvus-cm-activeline")
        $("body").append("<style id='salvus-cm-activeline' type=text/css>.CodeMirror-activeline{background:rgb(#{v[0]},#{v[1]},#{v[2]});}</style>")


    # hide/show the second linked codemirror editor, depending on whether or not it's enabled
    _show_extra_codemirror_view: () =>
        if @_split_view
            $(@codemirror1.getWrapperElement()).show()
        else
            $(@codemirror1.getWrapperElement()).hide()

    _show_codemirror_editors: (height, width) =>
        # console.log("_show_codemirror_editors: #{width} x #{height}")
        if not width or not height
            return
        # in case of more than one view on the document...
        @_show_extra_codemirror_view()

        btn = @element.find("a[href=#split-view]")
        btn.find("i").hide()
        if not @_split_view
            @element.find(".salvus-editor-codemirror-input-container-layout-1").width(width)
            @element.find(".salvus-editor-resize-bar-layout-1").hide()
            @element.find(".salvus-editor-resize-bar-layout-2").hide()
            btn.find(".salvus-editor-layout-0").show()
            # one full editor
            v = [{cm:@codemirror,height:height,width:width}]
        else
            if @_layout == 1
                @element.find(".salvus-editor-codemirror-input-container-layout-1").width(width)
                @element.find(".salvus-editor-resize-bar-layout-1").show()
                @element.find(".salvus-editor-resize-bar-layout-2").hide()
                btn.find(".salvus-editor-layout-1").show()
                p = @_layout1_split_pos
                if not p?
                    p = 0.5
                p = Math.max(MIN_SPLIT,Math.min(MAX_SPLIT, p))
                v = [{cm:@codemirror,  height:height*p,     width:width},
                     {cm:@codemirror1, height:height*(1-p), width:width}]
            else
                @element.find(".salvus-editor-resize-bar-layout-1").hide()
                @element.find(".salvus-editor-resize-bar-layout-2").show()
                p = @_layout2_split_pos
                if not p?
                    p = 0.5
                p = Math.max(MIN_SPLIT,Math.min(MAX_SPLIT, p))
                width0 = width*p
                width1 = width*(1-p)
                btn.find(".salvus-editor-layout-2").show()
                e = @element.find(".salvus-editor-codemirror-input-container-layout-2")
                e.width(width)
                e.find(".salvus-editor-resize-bar-layout-2").height(height).css(left : e.offset().left + width*p)
                e.find(".salvus-editor-codemirror-input-box").width(width0-7)
                v = [{cm:@codemirror,  height:height, width:width0},
                     {cm:@codemirror1, height:height, width:width1-8}]

        if @_last_layout != @_layout
            # move the editors to the correct layout template and show it.
            @element.find(".salvus-editor-codemirror-input-container-layout-#{@_last_layout}").hide()
            layout_elt = @element.find(".salvus-editor-codemirror-input-container-layout-#{@_layout}").show()
            layout_elt.find(".salvus-editor-codemirror-input-box").empty().append($(@codemirror.getWrapperElement()))
            layout_elt.find(".salvus-editor-codemirror-input-box-1").empty().append($(@codemirror1.getWrapperElement()))
            @_last_layout = @_layout

        # need to do this since theme may have changed
        # @_style_active_line()

        # CRAZY HACK: add and remove an HTML element to the DOM.
        # I don't know why this works, but it gets around a *massive bug*, where after
        # aggressive resizing, the codemirror editor gets all corrupted. For some reason,
        # doing this "usually" causes things to get properly fixed.  I don't know why.
        hack = $("<div><br><br><br><br></div>")
        $("body").append(hack)
        setTimeout((()=>hack.remove()), 10000)

        for {cm,height,width} in v
            scroller = $(cm.getScrollerElement())
            scroller.css('height':height)
            cm_wrapper = $(cm.getWrapperElement())
            cm_wrapper.css
                height : height
                width  : width

        # This is another hack that specifically hopefully addresses an
        # issue where when I open a tab often the scrollbar is completely
        # hosed.  Zooming in and out manually always fixes it, so maybe
        # what's below will also.  Testing it.
        f = () =>
            for {cm,height,width} in v
                cm.refresh()
                setTimeout((()=>cm.refresh), 1)
                ###
                scroll = cm.getScrollInfo(); pos = cm.getCursor()
                # above refresh
                scroll_after = cm.getScrollInfo(); pos_after = cm.getCursor()
                if scroll.left != scroll_after.left or scroll.top != scroll_after.top or pos.line != pos_after.line or pos.ch != pos_after.ch
                    console.log("WARNING: codemirror refresh lost pos -- RESETTING position; before=#{misc.to_json([scroll,pos])}, after=#{misc.to_json([scroll_after,pos_after])}")
                    cm.setCursor(pos)
                    cm.scrollTo(scroll.left, scroll.top)
                ###
        setTimeout(f, 1)

        @emit('show', height)


    _show: (opts={}) =>

        # show the element that contains this editor
        @element.show()

        # do size computations: determine height and width of the codemirror editor(s)
        if not opts.top?
            top           = @editor.editor_top_position()
        else
            top           = opts.top

        height            = $(window).height()
        elem_height       = height - top - 5
        button_bar_height = @element.find(".salvus-editor-codemirror-button-row").height()
        font_height       = @codemirror.defaultTextHeight()
        chat              = @_chat_is_hidden? and not @_chat_is_hidden

        # width of codemirror editors
        if chat
            width         = @element.find(".salvus-editor-codemirror-chat-column").offset().left
        else
            width         = $(window).width()

        if opts.width?
            width         = opts.width

        if opts.top?
            top           = opts.top

        # height of codemirror editors
        cm_height         = Math.floor((elem_height - button_bar_height)/font_height) * font_height

        # position the editor element on the screen
        @element.css(top:top, left:0)
        # and position the chat column
        @element.find(".salvus-editor-codemirror-chat-column").css(top:top+button_bar_height)

        # set overall height of the element
        @element.height(elem_height)

        # show the codemirror editors, resizing as needed
        @_show_codemirror_editors(cm_height, width)

        if chat
            chat_elt = @element.find(".salvus-editor-codemirror-chat")
            chat_elt.height(cm_height)

            chat_output    = chat_elt.find(".salvus-editor-codemirror-chat-output")
            chat_input     = chat_elt.find(".salvus-editor-codemirror-chat-input")
            chat_input_top = $(window).height() - chat_input.height() - 15

            chat_input.offset({top:chat_input_top})
            chat_output.height(chat_input_top - chat_output.offset().top - 30)


    focus: () =>
        if not @codemirror?
            return
        @show()
        if not IS_MOBILE
            @codemirror_with_last_focus?.focus()

    ############
    # Editor button bar support code
    ############
    textedit_command: (cm, cmd, args) =>
        switch cmd
            when "link"
                cm.insert_link(cb:() => @syncdoc?.sync())
                return false  # don't return true or get an infinite recurse
            when "image"
                cm.insert_image(cb:() => @syncdoc?.sync())
                return false  # don't return true or get an infinite recurse
            when "SpecialChar"
                cm.insert_special_char(cb:() => @syncdoc?.sync())
                return false  # don't return true or get an infinite recurse
            else
                cm.edit_selection
                    cmd  : cmd
                    args : args
                @syncdoc?.sync()
                # needed so that dropdown menu closes when clicked.
                return true

    # add a textedit toolbar to the editor
    init_sagews_edit_buttons: () =>
        if @opts.readonly  # no editing button bar needed for read-only files
            return

        if IS_MOBILE  # no edit button bar on mobile either -- too big (for now at least)
            return

        if not require('account').account_settings.settings.editor_settings.extra_button_bar
            # explicitly disabled by user
            return

        NAME_TO_MODE = {xml:'%html', markdown:'%md', mediawiki:'%wiki'}
        for x in sagews_decorator_modes
            mode = x[0]
            name = x[1]
            v = name.split('-')
            if v.length > 1
                name = v[1]
            NAME_TO_MODE[name] = "%#{mode}"

        name_to_mode = (name) ->
            n = NAME_TO_MODE[name]
            if n?
                return n
            else
                return "%#{name}"

        # add the text editing button bar
        e = @element.find(".salvus-editor-codemirror-textedit-buttons")
        @textedit_buttons = templates.find(".salvus-editor-textedit-buttonbar").clone().hide()
        e.append(@textedit_buttons).show()

        # add the code editing button bar
        @codeedit_buttons = templates.find(".salvus-editor-codeedit-buttonbar").clone()
        e.append(@codeedit_buttons)

        # the r-editing button bar
        @redit_buttons =  templates.find(".salvus-editor-redit-buttonbar").clone()
        e.append(@redit_buttons)

        # the Julia-editing button bar
        @julia_edit_buttons =  templates.find(".salvus-editor-julia-edit-buttonbar").clone()
        e.append(@julia_edit_buttons)

        @cython_buttons =  templates.find(".salvus-editor-cython-buttonbar").clone()
        e.append(@cython_buttons)

        @fallback_buttons = templates.find(".salvus-editor-fallback-edit-buttonbar").clone()
        e.append(@fallback_buttons)

        all_edit_buttons = [@textedit_buttons, @codeedit_buttons, @redit_buttons,
                            @cython_buttons, @julia_edit_buttons, @fallback_buttons]

        # activite the buttons in the bar
        that = @
        edit_button_click = () ->
            args = $(this).data('args')
            cmd  = $(this).attr('href').slice(1)
            if cmd == 'todo'
                return
            if args? and typeof(args) != 'object'
                args = "#{args}"
                if args.indexOf(',') != -1
                    args = args.split(',')
            return that.textedit_command(that.focused_codemirror(), cmd, args)


        # TODO: activate color editing buttons -- for now just hide them
        @element.find(".sagews-output-editor-foreground-color-selector").hide()
        @element.find(".sagews-output-editor-background-color-selector").hide()


        @fallback_buttons.find("a[href=#todo]").click () =>
            bootbox.alert("<i class='fa fa-wrench' style='font-size: 18pt;margin-right: 1em;'></i> Button bar not yet implemented in <code>#{mode_display.text()}</code> cells.")
            return false

        for edit_buttons in all_edit_buttons
            edit_buttons.find("a").click(edit_button_click)
            edit_buttons.find("*[title]").tooltip(TOOLTIP_DELAY)

        mode_display = @element.find(".salvus-editor-codeedit-buttonbar-mode")
        set_mode_display = (name) ->
            #console.log("set_mode_display: #{name}")
            if name?
                mode_display.text(name_to_mode(name))
            else
                mode_display.text("")

        show_edit_buttons = (which_one, name) ->
            for edit_buttons in all_edit_buttons
                if edit_buttons == which_one
                    edit_buttons.show()
                else
                    edit_buttons.hide()
            set_mode_display(name)

        # The code below changes the bar at the top depending on where the cursor
        # is located.  We only change the edit bar if the cursor hasn't moved for
        # a while, to be more efficient, avoid noise, and be less annoying to the user.
        bar_timeout = undefined
        f = () =>
            if bar_timeout?
                clearTimeout(bar_timeout)
            bar_timeout = setTimeout(update_context_sensitive_bar, 250)

        update_context_sensitive_bar = () =>
            cm = @focused_codemirror()
            pos = cm.getCursor()
            name = cm.getModeAt(pos).name
            #console.log("update_context_sensitive_bar, pos=#{misc.to_json(pos)}, name=#{name}")
            if name in ['xml', 'stex', 'markdown', 'mediawiki']
                show_edit_buttons(@textedit_buttons, name)
            else if name == "r"
                show_edit_buttons(@redit_buttons, name)
            else if name == "julia"
                show_edit_buttons(@julia_edit_buttons, name)
            else if name == "cython"  # doesn't work yet, since name=python still
                show_edit_buttons(@cython_buttons, name)
            else if name == "python"  # doesn't work yet, since name=python still
                show_edit_buttons(@codeedit_buttons, "sage")
            else
                show_edit_buttons(@fallback_buttons, name)

        for cm in [@codemirror, @codemirror1]
            cm.on('cursorActivity', f)

        update_context_sensitive_bar()
        @element.find(".salvus-editor-codemirror-textedit-buttons").mathjax()


codemirror_session_editor = exports.codemirror_session_editor = (editor, filename, extra_opts) ->
    #console.log("codemirror_session_editor '#{filename}'")
    ext = filename_extension(filename)

    E = new CodeMirrorEditor(editor, filename, "", extra_opts)
    # Enhance the editor with synchronized session capabilities.
    opts =
        cursor_interval : E.opts.cursor_interval
        sync_interval   : E.opts.sync_interval

    switch ext
        when "sagews"
            # temporary.
            opts =
                cursor_interval : 2000
                sync_interval   : 250
            E.syncdoc = new (syncdoc.SynchronizedWorksheet)(E, opts)
            E.action_key = E.syncdoc.action
            E.custom_enter_key = E.syncdoc.enter_key
            E.interrupt_key = E.syncdoc.interrupt
            E.tab_nothing_selected = () => E.syncdoc.introspect()
        when "sage-history"
            # temporary
        else
            E.syncdoc = new (syncdoc.SynchronizedDocument)(E, opts)
    return E


###############################################
# LateX Editor
###############################################

# Make a (server-side) self-destructing temporary uuid-named directory in path.
tmp_dir = (opts) ->
    opts = defaults opts,
        project_id : required
        path       : required
        ttl        : 120            # self destruct in this many seconds
        cb         : required       # cb(err, directory_name)
    name = "." + uuid()   # hidden
    if "'" in opts.path
        opts.cb("there is a disturbing ' in the path: '#{opts.path}'")
        return
    remove_tmp_dir
        project_id : opts.project_id
        path       : opts.path
        tmp_dir    : name
        ttl        : opts.ttl
    salvus_client.exec
        project_id : opts.project_id
        path       : opts.path
        command    : "mkdir"
        args       : [name]
        cb         : (err, output) =>
            if err
                opts.cb("Problem creating temporary directory in '#{opts.path}'")
            else
                opts.cb(false, name)

remove_tmp_dir = (opts) ->
    opts = defaults opts,
        project_id : required
        path       : required
        tmp_dir    : required
        ttl        : 120            # run in this many seconds (even if client disconnects)
        cb         : undefined
    salvus_client.exec
        project_id : opts.project_id
        command    : "sleep #{opts.ttl} && rm -rf '#{opts.path}/#{opts.tmp_dir}'"
        timeout    : 10 + opts.ttl
        cb         : (err, output) =>
            cb?(err)


# Class that wraps "a remote latex doc with PDF preview":
class PDFLatexDocument
    constructor: (opts) ->
        opts = defaults opts,
            project_id : required
            filename   : required
            image_type : 'png'  # 'png' or 'jpg'

        @project_id = opts.project_id
        @filename   = opts.filename
        @image_type = opts.image_type

        @_pages     = {}
        @num_pages  = 0
        @latex_log  = ''
        s = path_split(@filename)
        @path = s.head
        if @path == ''
            @path = './'
        @filename_tex  = s.tail
        @base_filename = @filename_tex.slice(0, @filename_tex.length-4)
        @filename_pdf  =  @base_filename + '.pdf'

    page: (n) =>
        if not @_pages[n]?
            @_pages[n] = {}
        return @_pages[n]

    _exec: (opts) =>
        opts = defaults opts,
            path        : @path
            project_id  : @project_id
            command     : required
            args        : []
            timeout     : 30
            err_on_exit : false
            bash        : false
            cb          : required
        #console.log(opts.path)
        #console.log(opts.command + ' ' + opts.args.join(' '))
        salvus_client.exec(opts)

    spell_check: (opts) =>
        opts = defaults opts,
            lang : undefined
            cb   : required
        if not opts.lang?
            opts.lang = misc_page.language()
        if opts.lang == 'disable'
            opts.cb(undefined,[])
            return
        @_exec
            command : "cat '#{@filename_tex}'|aspell --mode=tex --lang=#{opts.lang} list|sort|uniq"
            bash    : true
            cb      : (err, output) =>
                if err
                    opts.cb(err); return
                if output.stderr
                    opts.cb(output.stderr); return
                opts.cb(undefined, output.stdout.slice(0,output.stdout.length-1).split('\n'))  # have to slice final \n

    inverse_search: (opts) =>
        opts = defaults opts,
            n          : required   # page number
            x          : required   # x coordinate in unscaled png image coords (as reported by click EventEmitter)...
            y          : required   # y coordinate in unscaled png image coords
            resolution : required   # resolution used in ghostscript
            cb         : required   # cb(err, {input:'file.tex', line:?})

        scale = opts.resolution / 72
        x = opts.x / scale
        y = opts.y / scale
        @_exec
            command : 'synctex'
            args    : ['edit', '-o', "#{opts.n}:#{x}:#{y}:#{@filename_pdf}"]
            path    : @path
            timeout : 7
            cb      : (err, output) =>
                if err
                    opts.cb(err); return
                if output.stderr
                    opts.cb(output.stderr); return
                s = output.stdout
                i = s.indexOf('\nInput:')
                input = s.slice(i+7, s.indexOf('\n',i+3))

                # normalize path to be relative to project home
                j = input.indexOf('/./')
                if j != -1
                    fname = input.slice(j+3)
                else
                    j = input.indexOf('/../')
                    if j != -1
                        fname = input.slice(j+1)
                    else
                        fname = input
                if @path != './'
                    input = @path + '/' + fname
                else
                    input = fname

                i = s.indexOf('Line')
                line = parseInt(s.slice(i+5, s.indexOf('\n',i+1)))
                opts.cb(false, {input:input, line:line-1})   # make line 0-based

    forward_search: (opts) =>
        opts = defaults opts,
            n  : required
            cb : required   # cb(err, {page:?, x:?, y:?})    x,y are in terms of 72dpi pdf units

        @_exec
            command : 'synctex'
            args    : ['view', '-i', "#{opts.n}:0:#{@filename_tex}", '-o', @filename_pdf]
            path    : @path
            cb      : (err, output) =>
                if err
                    opts.cb(err); return
                if output.stderr
                    opts.cb(output.stderr); return
                s = output.stdout
                i = s.indexOf('\nPage:')
                n = s.slice(i+6, s.indexOf('\n',i+3))
                i = s.indexOf('\nx:')
                x = parseInt(s.slice(i+3, s.indexOf('\n',i+3)))
                i = s.indexOf('\ny:')
                y = parseInt(s.slice(i+3, s.indexOf('\n',i+3)))
                opts.cb(false, {n:n, x:x, y:y})

    default_tex_command: () =>
        a = "pdflatex -synctex=1 -interact=nonstopmode "
        if @filename_tex.indexOf(' ') != -1
            a += "'#{@filename_tex}'"
        else
            a += @filename_tex
        return a

    # runs pdflatex; updates number of pages, latex log, parsed error log
    update_pdf: (opts={}) =>
        opts = defaults opts,
            status        : undefined  # status(start:'latex' or 'sage' or 'bibtex'), status(end:'latex', 'log':'output of thing running...')
            latex_command : undefined
            cb            : undefined
        @pdf_updated = true
        if not opts.latex_command?
            opts.latex_command = @default_tex_command()
        @_need_to_run = {}
        log = ''
        status = opts.status
        async.series([
            (cb) =>
                 status?(start:'latex')
                 @_run_latex opts.latex_command, (err, _log) =>
                     log += _log
                     status?(end:'latex', log:_log)
                     cb(err)
            (cb) =>
                 if @_need_to_run.sage
                     status?(start:'sage')
                     @_run_sage @_need_to_run.sage, (err, _log) =>
                         log += _log
                         status?(end:'sage', log:_log)
                         cb(err)
                 else
                     cb()
            (cb) =>
                 if @_need_to_run.bibtex
                     status?(start:'bibtex')
                     @_run_bibtex (err, _log) =>
                         status?(end:'bibtex', log:_log)
                         log += _log
                         cb(err)
                 else
                     cb()
            (cb) =>
                 if @_need_to_run.latex
                     status?(start:'latex')
                     @_run_latex opts.latex_command, (err, _log) =>
                          log += _log
                          status?(end:'latex', log:_log)
                          cb(err)
                 else
                     cb()
            (cb) =>
                 if @_need_to_run.latex
                     status?(start:'latex')
                     @_run_latex opts.latex_command, (err, _log) =>
                          log += _log
                          status?(end:'latex', log:_log)
                          cb(err)
                 else
                     cb()
            (cb) =>
                @update_number_of_pdf_pages(cb)
        ], (err) =>
            opts.cb?(err, log))

    _run_latex: (command, cb) =>
        if not command?
            command = @default_tex_command()
        sagetex_file = @base_filename + '.sagetex.sage'
        sha_marker = 'sha1sums'
        @_exec
            command : command + "< /dev/null 2</dev/null; echo '#{sha_marker}'; sha1sum '#{sagetex_file}'"
            bash    : true
            timeout : 20
            err_on_exit : false
            cb      : (err, output) =>
                if err
                    cb?(err)
                else
                    i = output.stdout.lastIndexOf(sha_marker)
                    if i != -1
                        shas = output.stdout.slice(i+sha_marker.length+1)
                        output.stdout = output.stdout.slice(0,i)
                        for x in shas.split('\n')
                            v = x.split(/\s+/)
                            if v[1] == sagetex_file and v[0] != @_sagetex_file_sha
                                @_need_to_run.sage = sagetex_file
                                @_sagetex_file_sha = v[0]

                    log = output.stdout + '\n\n' + output.stderr

                    if log.indexOf('Rerun to get cross-references right') != -1
                        @_need_to_run.latex = true

                    run_sage_on = '\nRun Sage on'
                    i = log.indexOf(run_sage_on)
                    if i != -1
                        j = log.indexOf(', and then run LaTeX', i)
                        if j != -1
                            # the .replace(/"/g,'') is because sagetex tosses "'s around part of the filename
                            # in some cases, e.g., when it has a space in it.  Tex itself won't accept
                            # filenames with quotes, so this replacement isn't dangerous.  We don't need
                            # or want these quotes, since we're not passing this command via bash/sh.
                            @_need_to_run.sage = log.slice(i + run_sage_on.length, j).trim().replace(/"/g,'')

                    i = log.indexOf("No file #{@base_filename}.bbl.")
                    if i != -1
                        @_need_to_run.bibtex = true

                    @last_latex_log = log
                    cb?(false, log)

    _run_sage: (target, cb) =>
        if not target?
            target = @base_filename + '.sagetex.sage'
        @_exec
            command : 'sage'
            args    : [target]
            timeout : 45
            cb      : (err, output) =>
                if err
                    cb?(err)
                else
                    log = output.stdout + '\n\n' + output.stderr
                    @_need_to_run.latex = true
                    cb?(false, log)

    _run_bibtex: (cb) =>
        @_exec
            command : 'bibtex'
            args    : [@base_filename]
            timeout : 10
            cb      : (err, output) =>
                if err
                    cb?(err)
                else
                    log = output.stdout + '\n\n' + output.stderr
                    @_need_to_run.latex = true
                    cb?(false, log)

    pdfinfo: (cb) =>   # cb(err, info)
        @_exec
            command     : "pdfinfo"
            args        : [@filename_pdf]
            bash        : false
            err_on_exit : true
            cb          : (err, output) =>
                if err
                    cb(err)
                    return
                v = {}
                for x in output.stdout?.split('\n')
                    w = x.split(':')
                    if w.length == 2
                        v[w[0].trim()] = w[1].trim()
                cb(undefined, v)

    update_number_of_pdf_pages: (cb) =>
        before = @num_pages
        @pdfinfo (err, info) =>
            # if err maybe no pdf yet -- just don't do anything
            if not err and info?.Pages?
                @num_pages = info.Pages
                # Delete trailing removed pages from our local view of things; otherwise, they won't properly
                # re-appear later if they look identical, etc.
                if @num_pages < before
                    for n in [@num_pages ... before]
                        delete @_pages[n]
            cb()

    # runs pdftotext; updates plain text of each page.
    # (not used right now, since we are using synctex instead...)
    update_text: (cb) =>
        @_exec
            command : "pdftotext"   # part of the "calibre" ubuntu package
            args    : [@filename_pdf, '-']
            cb      : (err, output) =>
                if not err
                    @_parse_text(output.stdout)
                cb?(err)

    trash_aux_files: (cb) =>
        EXT = ['aux', 'log', 'bbl', 'synctex.gz', 'sagetex.py', 'sagetex.sage', 'sagetex.scmd', 'sagetex.sout']
        @_exec
            command : "rm"
            args    : (@base_filename + "." + ext for ext in EXT)
            cb      : cb

    _parse_text: (text) =>
        # todo -- parse through the text file putting the pages in the correspondings @pages dict.
        # for now... for debugging.
        @_text = text
        n = 1
        for t in text.split('\x0c')  # split on form feed
            @page(n).text = t
            n += 1

    # Updates previews for a given range of pages.
    # This computes images on backend, and fills in the sha1 hashes of @pages.
    # If any sha1 hash changes from what was already there, it gets temporary
    # url for that file.
    # It assumes the pdf files is there already, and doesn't run pdflatex.
    update_images: (opts={}) =>
        opts = defaults opts,
            first_page : 1
            last_page  : undefined  # defaults to @num_pages, unless 0 in which case 99999
            cb         : undefined  # cb(err, [array of page numbers of pages that changed])
            resolution : 50         # number
            device     : '16m'      # one of '16', '16m', '256', '48', 'alpha', 'gray', 'mono'  (ignored if image_type='jpg')
            png_downscale : 2       # ignored if image type is jpg
            jpeg_quality  : 75      # jpg only -- scale of 1 to 100

        res = opts.resolution
        if @image_type == 'png'
            res /= opts.png_downscale

        if not opts.last_page?
            opts.last_page = @num_pages
            if opts.last_page == 0
                opts.last_page = 99999

        #console.log("opts.last_page = ", opts.last_page)

        if opts.first_page <= 0
            opts.first_page = 1

        if opts.last_page < opts.first_page
            # easy peasy
            opts.cb?(false,[])
            return

        tmp = undefined
        sha1_changed = []
        changed_pages = []
        pdf = undefined
        async.series([
            (cb) =>
                tmp_dir
                    project_id : @project_id
                    path       : "/tmp"
                    ttl        : 180
                    cb         : (err, _tmp) =>
                        tmp = "/tmp/#{_tmp}"
                        cb(err)
            (cb) =>
                pdf = "#{tmp}/#{@filename_pdf}"
                @_exec
                    command : 'cp'
                    args    : [@filename_pdf, pdf]
                    timeout : 15
                    err_on_exit : true
                    cb      : cb
            (cb) =>
                if @image_type == "png"
                    args = ["-r#{opts.resolution}",
                               '-dBATCH', '-dNOPAUSE',
                               "-sDEVICE=png#{opts.device}",
                               "-sOutputFile=#{tmp}/%d.png",
                               "-dFirstPage=#{opts.first_page}",
                               "-dLastPage=#{opts.last_page}",
                               "-dDownScaleFactor=#{opts.png_downscale}",
                               pdf]
                else if @image_type == "jpg"
                    args = ["-r#{opts.resolution}",
                               '-dBATCH', '-dNOPAUSE',
                               '-sDEVICE=jpeg',
                               "-sOutputFile=#{tmp}/%d.jpg",
                               "-dFirstPage=#{opts.first_page}",
                               "-dLastPage=#{opts.last_page}",
                               "-dJPEGQ=#{opts.jpeg_quality}",
                               pdf]
                else
                    cb("unknown image type #{@image_type}")
                    return

                #console.log('gs ' + args.join(" "))
                @_exec
                    command : 'gs'
                    args    : args
                    err_on_exit : true
                    timeout : 120
                    cb      : (err, output) ->
                        cb(err)

            # get the new sha1 hashes
            (cb) =>
                @_exec
                    command : "sha1sum *.png *.jpg"
                    bash    : true
                    path    : tmp
                    timeout : 15
                    cb      : (err, output) =>
                        if err
                            cb(err); return
                        for line in output.stdout.split('\n')
                            v = line.split(' ')
                            if v.length > 1
                                try
                                    filename = v[2]
                                    n = parseInt(filename.split('.')[0]) + opts.first_page - 1
                                    if @page(n).sha1 != v[0]
                                        sha1_changed.push( page_number:n, sha1:v[0], filename:filename )
                                catch e
                                    console.log("sha1sum: error parsing line=#{line}")
                        cb()

            # get the images whose sha1's changed
            (cb) =>
                #console.log("sha1_changed = ", sha1_changed)
                update = (obj, cb) =>
                    n = obj.page_number
                    salvus_client.read_file_from_project
                        project_id : @project_id
                        path       : "#{tmp}/#{obj.filename}"
                        timeout    : 5  # a single page shouldn't take long
                        cb         : (err, result) =>
                            if err
                                cb(err)
                            else if not result.url?
                                cb("no url in result for a page")
                            else
                                p = @page(n)
                                p.sha1 = obj.sha1
                                p.url = result.url
                                p.resolution = res
                                changed_pages.push(n)
                                cb()
                async.mapSeries(sha1_changed, update, cb)
        ], (err) =>
            opts.cb?(err, changed_pages)
        )

# FOR debugging only
exports.PDFLatexDocument = PDFLatexDocument

class PDF_Preview extends FileEditor
    constructor: (@editor, @filename, contents, opts) ->
        @pdflatex = new PDFLatexDocument(project_id:@editor.project_id, filename:@filename, image_type:"png")
        @opts = opts
        @_updating = false
        @element = templates.find(".salvus-editor-pdf-preview").clone()
        @spinner = @element.find(".salvus-editor-pdf-preview-spinner")
        s = path_split(@filename)
        @path = s.head
        if @path == ''
            @path = './'
        @file = s.tail
        @element.maxheight()
        @last_page = 0
        @output = @element.find(".salvus-editor-pdf-preview-page")
        @highlight = @element.find(".salvus-editor-pdf-preview-highlight").hide()
        @output.text("Loading preview...")
        @_first_output = true
        @_needs_update = true


    zoom: (opts) =>
        opts = defaults opts,
            delta : undefined
            width : undefined

        images = @output.find("img")
        if images.length == 0
            return # nothing to do

        if opts.delta?
            if not @zoom_width?
                @zoom_width = 160   # NOTE: hardcoded also in editor.css class .salvus-editor-pdf-preview-image
            max_width = @zoom_width
            max_width += opts.delta
        else if opts.width?
            max_width = opts.width

        if max_width?
            @zoom_width = max_width
            n = @current_page().number
            max_width = "#{max_width}%"
            images.css
                'max-width'   : max_width
                width         : max_width
            @scroll_into_view(n : n, highlight_line:false, y:$(window).height()/2)

        @recenter()

    recenter: () =>
        container_width = @output.find(":first-child:first").width()
        content_width = @output.find("img:first-child:first").width()
        @output.scrollLeft((content_width - container_width)/2)

    watch_scroll: () =>
        if @_f?
            clearInterval(@_f)
        timeout = undefined
        @output.on 'scroll', () =>
            @_needs_update = true
        f = () =>
            if @_needs_update and @element.is(':visible')
                @_needs_update = false
                @update cb:(err) =>
                    if err
                        @_needs_update = true
        @_f = setInterval(f, 1000)

    highlight_middle: (fade_time) =>
        if not fade_time?
            fade_time = 5000
        @highlight.show().offset(top:$(window).height()/2)
        @highlight.stop().animate(opacity:.3).fadeOut(fade_time)

    scroll_into_view: (opts) =>
        opts = defaults opts,
            n              : required   # page
            y              : 0          # y-coordinate on page
            highlight_line : true
        pg = @pdflatex.page(opts.n)
        if not pg?
            # the page has vanished in the meantime...
            return
        t = @output.offset().top
        @output.scrollTop(0)  # reset to 0 first so that pg.element.offset().top is correct below
        top = (pg.element.offset().top + opts.y) - $(window).height() / 2
        @output.scrollTop(top)
        if opts.highlight_line
            # highlight location of interest
            @highlight_middle()

    remove: () =>
        if @_f?
            clearInterval(@_f)
        @element.remove()

    focus: () =>
        @element.maxheight()
        @output.height(@element.height())
        @output.width(@element.width())

    current_page: () =>
        tp = @output.offset().top
        for _page in @output.children()
            page = $(_page)
            offset = page.offset()
            if offset.top > tp
                n = page.data('number')
                if n > 1
                    n -= 1
                return {number:n, offset:offset.top}
        if page?
            return {number:page.data('number')}
        else
            return {number:1}

    update: (opts={}) =>
        opts = defaults opts,
            window_size : 4
            cb          : undefined

        if @_updating
            opts.cb?("already updating")  # don't change string
            return

        #@spinner.show().spin(true)
        @_updating = true

        @output.maxheight()
        if @element.width()
            @output.width(@element.width())

        # Remove trailing pages from DOM.
        if @pdflatex.num_pages?
            # This is O(N), but behaves better given the async nature...
            for p in @output.children()
                page = $(p)
                if page.data('number') > @pdflatex.num_pages
                    page.remove()

        n = @current_page().number

        f = (opts, cb) =>
            opts.cb = (err, changed_pages) =>
                if err
                    cb(err)
                else if changed_pages.length == 0
                    cb()
                else
                    g = (n, cb) =>
                        @_update_page(n, cb)
                    async.map(changed_pages, g, cb)
            @pdflatex.update_images(opts)

        hq_window = opts.window_size
        if n == 1
            hq_window *= 2

        f {first_page : n, last_page  : n+1, resolution:@opts.resolution*3, device:'16m', png_downscale:3}, (err) =>
            if err
                #@spinner.spin(false).hide()
                @_updating = false
                opts.cb?(err)
            else if not @pdflatex.pdf_updated? or @pdflatex.pdf_updated
                @pdflatex.pdf_updated = false
                g = (obj, cb) =>
                    if obj[2]
                        f({first_page:obj[0], last_page:obj[1], resolution:'300', device:'16m', png_downscale:3}, cb)
                    else
                        f({first_page:obj[0], last_page:obj[1], resolution:'150', device:'gray', png_downscale:1}, cb)
                v = []
                v.push([n-hq_window, n-1, true])
                v.push([n+2, n+hq_window, true])

                k1 = Math.round((1 + n-hq_window-1)/2)
                v.push([1, k1])
                v.push([k1+1, n-hq_window-1])
                if @pdflatex.num_pages
                    k2 = Math.round((n+hq_window+1 + @pdflatex.num_pages)/2)
                    v.push([n+hq_window+1,k2])
                    v.push([k2,@pdflatex.num_pages])
                else
                    v.push([n+hq_window+1,999999])
                async.map v, g, (err) =>
                    #@spinner.spin(false).hide()
                    @_updating = false

                    # If first time, start watching for scroll movements to update.
                    if not @_f?
                        @watch_scroll()
                    opts.cb?()
            else
                @_updating = false
                opts.cb?()


    # update page n based on currently computed data.
    _update_page: (n, cb) =>
        p          = @pdflatex.page(n)
        url        = p.url
        resolution = p.resolution
        if not url?
            # delete page and all following it from DOM
            for m in [n .. @last_page]
                @output.remove(".salvus-editor-pdf-preview-page-#{m}")
            if @last_page >= n
                @last_page = n-1
        else
            # update page
            recenter = (@last_page == 0)
            that = @
            page = @output.find(".salvus-editor-pdf-preview-page-#{n}")
            if page.length == 0
                # create
                for m in [@last_page+1 .. n]
                    page = $("<div style='text-align:center;' class='salvus-editor-pdf-preview-page-#{m}'><img alt='Page #{m}' class='salvus-editor-pdf-preview-image'><br></div>")
                    page.data("number", m)

                    f = (e) ->
                        pg = $(e.delegateTarget)
                        n  = pg.data('number')
                        offset = $(e.target).offset()
                        x = e.pageX - offset.left
                        y = e.pageY - offset.top
                        img = pg.find("img")
                        nH = img[0].naturalHeight
                        nW = img[0].naturalWidth
                        y *= nH/img.height()
                        x *= nW/img.width()
                        that.emit 'shift-click', {n:n, x:x, y:y, resolution:img.data('resolution')}
                        return false

                    page.click (e) ->
                        if e.shiftKey or e.ctrlKey
                            f(e)
                        return false

                    page.dblclick(f)

                    if self._margin_left?
                        # A zoom was set via the zoom command -- maintain it.
                        page.find("img").css
                            'max-width'   : self._max_width
                            width         : self._max_width

                    if @_first_output
                        @output.empty()
                        @_first_output = false

                    # Insert page in the right place in the output.  Since page creation
                    # can happen in parallel/random order (esp because of deletes of trailing pages),
                    # we have to work at this a bit.
                    done = false
                    for p in @output.children()
                        pg = $(p)
                        if pg.data('number') > m
                            page.insertBefore(pg)
                            done = true
                            break
                    if not done
                        @output.append(page)

                    @pdflatex.page(m).element = page

                @last_page = n
            img =  page.find("img")
            #console.log("setting an img src to", url)
            img.attr('src', url).data('resolution', resolution)
            load_error = () ->
                img.off('error', load_error)
                setTimeout((()->img.attr('src',url)), 2000)
            img.on('error', load_error)

            if recenter
                img.one 'load', () =>
                    @recenter()

            if @zoom_width?
                max_width = @zoom_width
                max_width = "#{max_width}%"
                img.css
                    'max-width'   : max_width
                    width         : max_width

            #page.find(".salvus-editor-pdf-preview-text").text(p.text)
        cb()

    show: (geometry={}) =>
        geometry = defaults geometry,
            left   : undefined
            top    : undefined
            width  : $(window).width()
            height : undefined
        if not @is_active()
            return

        @element.show()

        f = () =>
            @element.width(geometry.width)
            @element.offset
                left : geometry.left
                top  : geometry.top

            if geometry.height?
                @element.height(geometry.height)
            else
                @element.maxheight()
                geometry.height = @element.height()

            @focus()
        # We wait a tick for the element to appear before positioning it, otherwise it
        # can randomly get messed up.
        setTimeout(f, 1)

    hide: () =>
        @element.hide()


class PDF_PreviewEmbed extends FileEditor
    constructor: (@editor, @filename, contents, @opts) ->
        @element = templates.find(".salvus-editor-pdf-preview-embed").clone()
        @element.find(".salvus-editor-pdf-title").text(@filename)

        @spinner = @element.find(".salvus-editor-pdf-preview-embed-spinner")

        s = path_split(@filename)
        @path = s.head
        if @path == ''
            @path = './'
        @file = s.tail

        @output = @element.find(".salvus-editor-pdf-preview-embed-page")

        @element.find("a[href=#refresh]").click () =>
            @update()
            return false

        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

    focus: () =>

    update: (cb) =>
        height = @element.height()
        if height == 0
            # not visible.
            return
        width = @element.width()

        button = @element.find("a[href=#refresh]")
        button.icon_spin(true)

        @_last_width = width
        @_last_height = height

        output_height = height - ( @output.offset().top - @element.offset().top)
        @output.height(output_height)
        @output.width(width)

        @spinner.show().spin(true)
        salvus_client.read_file_from_project
            project_id : @editor.project_id
            path       : @filename
            timeout    : 20
            cb         : (err, result) =>
                button.icon_spin(false)
                @spinner.spin(false).hide()
                if err or not result.url?
                    alert_message(type:"error", message:"unable to get pdf -- #{err}")
                else
                    @output.html("<object data=\"#{result.url}\" type='application/pdf' width='#{width}' height='#{output_height-10}'><br><br>Your browser doesn't support embedded PDF's, but you can <a href='#{result.url}&random=#{Math.random()}'>download #{@filename}</a></p></object>")

    show: (geometry={}) =>
        geometry = defaults geometry,
            left   : undefined
            top    : undefined
            width  : $(window).width()
            height : undefined

        @element.show()
        if not geometry.top?
            @element.css(top:@editor.editor_top_position())

        if geometry.height?
            @element.height(geometry.height)
        else
            @element.maxheight()
            geometry.height = @element.height()

        @element.width(geometry.width)

        @element.offset
            left : geometry.left
            top  : geometry.top

        if @_last_width != geometry.width or @_last_height != geometry.height
            @update()

        @focus()

    hide: () =>
        @element.hide()



#############################################
# Editor for LaTeX documents
#############################################

class LatexEditor extends FileEditor
    constructor: (@editor, @filename, content, opts) ->
        # The are three components:
        #     * latex_editor -- a CodeMirror editor
        #     * preview -- display the images (page forward/backward/resolution)
        #     * log -- log of latex command
        opts.mode = 'stex2'

        @element = templates.find(".salvus-editor-latex").clone()

        @_pages = {}

        # initialize the latex_editor
        @latex_editor = codemirror_session_editor(@editor, filename, opts)
        @_pages['latex_editor'] = @latex_editor
        @element.find(".salvus-editor-latex-latex_editor").append(@latex_editor.element)
        @latex_editor.action_key = @action_key
        @element.find(".salvus-editor-latex-buttons").show()

        latex_buttonbar = @element.find(".salvus-editor-latex-buttonbar")
        latex_buttonbar.show()

        @latex_editor.syncdoc.on 'connect', () =>
            @preview.zoom_width = @load_conf().zoom_width
            @update_preview()
            @spell_check()

        v = path_split(@filename)
        @_path = v.head
        @_target = v.tail

        # initialize the previews
        n = @filename.length

        # The pdf preview.
        @preview = new PDF_Preview(@editor, @filename, undefined, {resolution:200})
        @element.find(".salvus-editor-latex-png-preview").append(@preview.element)
        @_pages['png-preview'] = @preview
        @preview.on 'shift-click', (opts) => @_inverse_search(opts)

        # Embedded pdf page (not really a "preview" -- it's the real thing).
        @preview_embed = new PDF_PreviewEmbed(@editor, @filename.slice(0,n-3)+"pdf", undefined, {})
        @element.find(".salvus-editor-latex-pdf-preview").append(@preview_embed.element)
        @preview_embed.element.find(".salvus-editor-pdf-title").hide()
        @preview_embed.element.find("a[href=#refresh]").hide()
        @_pages['pdf-preview'] = @preview_embed

        # Initalize the log
        @log = @element.find(".salvus-editor-latex-log")
        @log.find("a").tooltip(delay:{ show: 500, hide: 100 })
        @_pages['log'] = @log
        @log_input = @log.find("input")
        @log_input.keyup (e) =>
            if e.keyCode == 13
                latex_command = @log_input.val()
                @set_conf_doc(latex_command: latex_command)
                @save()

        @errors = @element.find(".salvus-editor-latex-errors")
        @_pages['errors'] = @errors
        @_error_message_template = @element.find(".salvus-editor-latex-mesg-template")

        @_init_buttons()
        @init_draggable_split()

        # this is entirely because of the chat
        # currently being part of @latex_editor, and
        # only calling the show for that; once chat
        # is refactored out, delete this.
        @latex_editor.on 'show-chat', () =>
            @show()
        @latex_editor.on 'hide-chat', () =>
            @show()

        # This synchronizes the editor and png preview -- it's kind of disturbing.
        # If people request it, make it a non-default option...
        if false
            @preview.output.on 'scroll', @_passive_inverse_search
            cm0 = @latex_editor.codemirror
            cm1 = @latex_editor.codemirror1
            cm0.on 'cursorActivity', @_passive_forward_search
            cm1.on 'cursorActivity', @_passive_forward_search
            cm0.on 'change', @_pause_passive_search
            cm1.on 'change', @_pause_passive_search

    spell_check: (cb) =>
        @preview.pdflatex.spell_check
            lang : @load_conf_doc().lang
            cb   : (err, words) =>
                if err
                    cb?(err)
                else
                    @latex_editor.codemirror.spellcheck_highlight(words)
                    @latex_editor.codemirror1.spellcheck_highlight(words)

    init_draggable_split: () =>
        @_split_pos = @local_storage("split_pos")
        @_dragbar = dragbar = @element.find(".salvus-editor-latex-resize-bar")
        dragbar.css(position:'absolute')
        dragbar.draggable
            axis : 'x'
            containment : @element
            zIndex      : 100
            stop        : (event, ui) =>
                # compute the position of bar as a number from 0 to 1
                left  = @element.offset().left
                chat_pos = @element.find(".salvus-editor-codemirror-chat").offset()
                if chat_pos.left
                    width = chat_pos.left - left
                else
                    width = @element.width()
                p     = dragbar.offset().left
                @_split_pos = (p - left) / width
                @local_storage('split_pos', @_split_pos)
                #dragbar.css(left: )
                @show()

    set_conf: (obj) =>
        conf = @load_conf()
        for k, v of obj
            conf[k] = v
        @save_conf(conf)

    load_conf: () =>
        conf = @local_storage('conf')
        if not conf?
            conf = {}
        return conf

    save_conf: (conf) =>
        @local_storage('conf', conf)


    set_conf_doc: (obj) =>
        conf = @load_conf_doc()
        for k, v of obj
            conf[k] = v
        @save_conf_doc(conf)

    load_conf_doc: () =>
        doc = @latex_editor.codemirror.getValue()
        i = doc.indexOf("%sagemathcloud=")
        if i == -1
            return {}

        j = doc.indexOf('=',i)
        k = doc.indexOf('\n',i)
        if k == -1
            k = doc.length
        try
            conf = misc.from_json(doc.slice(j+1,k))
        catch e
            conf = {}

        return conf

    save_conf_doc: (conf) =>
        cm  = @latex_editor.codemirror
        doc = cm.getValue()
        i = doc.indexOf('%sagemathcloud=')
        line = '%sagemathcloud=' + misc.to_json(conf)
        if i != -1
            # find the line m where it is already
            for n in [0..cm.doc.lastLine()]
                z = cm.getLine(n)
                if z.indexOf('%sagemathcloud=') != -1
                    m = n
                    break
            cm.replaceRange(line+'\n', {line:m,ch:0}, {line:m+1,ch:0})
        else
            if misc.len(conf) == 0
                # don't put it in there if empty
                return
            cm.replaceRange('\n'+line, {line:cm.doc.lastLine()+1,ch:0})
        @latex_editor.syncdoc.sync()

    _pause_passive_search: (cb) =>
        @_passive_forward_search_disabled = true
        @_passive_inverse_search_disabled = true
        f = () =>
            @_passive_inverse_search_disabled = false
            @_passive_forward_search_disabled = false

        setTimeout(f, 3000)


    _passive_inverse_search: (cb) =>
        if @_passive_inverse_search_disabled
            cb?(); return
        @_pause_passive_search()
        @inverse_search
            active : false
            cb     : (err) =>
                cb?()

    _passive_forward_search: (cb) =>
        if @_passive_forward_search_disabled
            cb?(); return
        @forward_search
            active : false
            cb     : (err) =>
                @_pause_passive_search()
                cb?()

    action_key: () =>
        @show_page('png-preview')
        @forward_search(active:true)

    remove: () =>
        @element.remove()
        @preview.remove()
        @preview_embed.remove()

    _init_buttons: () =>
        @element.find("a").tooltip(delay:{ show: 500, hide: 100 } )

        @element.find("a[href=#forward-search]").click () =>
            @show_page('png-preview')
            @forward_search(active:true)
            return false

        @element.find("a[href=#inverse-search]").click () =>
            @show_page('png-preview')
            @inverse_search(active:true)
            return false

        @element.find("a[href=#png-preview]").click () =>
            @show_page('png-preview')
            @preview.focus()
            @save()
            return false

        @element.find("a[href=#zoom-preview-out]").click () =>
            @preview.zoom(delta:-5)
            @set_conf(zoom_width:@preview.zoom_width)
            return false

        @element.find("a[href=#zoom-preview-in]").click () =>
            @preview.zoom(delta:5)
            @set_conf(zoom_width:@preview.zoom_width)
            return false

        @element.find("a[href=#zoom-preview-fullpage]").click () =>
            @preview.zoom(width:100)
            @set_conf(zoom_width:@preview.zoom_width)
            return false

        @element.find("a[href=#zoom-preview-width]").click () =>
            @preview.zoom(width:160)
            @set_conf(zoom_width:@preview.zoom_width)
            return false


        @element.find("a[href=#pdf-preview]").click () =>
            @show_page('pdf-preview')
            @preview_embed.focus()
            @preview_embed.update()
            return false

        @element.find("a[href=#log]").click () =>
            @show_page('log')
            @element.find(".salvus-editor-latex-log").find("textarea").maxheight()
            t = @log.find("textarea")
            t.scrollTop(t[0].scrollHeight)
            return false

        @element.find("a[href=#errors]").click () =>
            @show_page('errors')
            return false

        @number_of_errors = @element.find("a[href=#errors]").find(".salvus-latex-errors-counter")
        @number_of_warnings = @element.find("a[href=#errors]").find(".salvus-latex-warnings-counter")

        @element.find("a[href=#pdf-download]").click () =>
            @download_pdf()
            return false

        @element.find("a[href=#preview-resolution]").click () =>
            @set_resolution()
            return false

        @element.find("a[href=#latex-command-undo]").click () =>
            c = @preview.pdflatex.default_tex_command()
            @log_input.val(c)
            @set_conf_doc(latex_command: c)
            return false

        trash_aux_button = @element.find("a[href=#latex-trash-aux]")
        trash_aux_button.click () =>
            trash_aux_button.icon_spin(true)
            @preview.pdflatex.trash_aux_files () =>
                trash_aux_button.icon_spin(false)
            return false

        run_sage = @element.find("a[href=#latex-sage]")
        run_sage.click () =>
            @log.find("textarea").text("Running Sage...")
            run_sage.icon_spin(true)
            @preview.pdflatex._run_sage undefined, (err, log) =>
                run_sage.icon_spin(false)
                @log.find("textarea").text(log)
            return false

        run_latex = @element.find("a[href=#latex-latex]")
        run_latex.click () =>
            @log.find("textarea").text("Running Latex...")
            run_latex.icon_spin(true)
            @preview.pdflatex._run_latex @load_conf_doc().latex_command, (err, log) =>
                run_latex.icon_spin(false)
                @log.find("textarea").text(log)
            return false

        run_bibtex = @element.find("a[href=#latex-bibtex]")
        run_bibtex.click () =>
            @log.find("textarea").text("Running Bibtex...")
            run_bibtex.icon_spin(true)
            @preview.pdflatex._run_bibtex (err, log) =>
                run_bibtex.icon_spin(false)
                @log.find("textarea").text(log)
            return false


    set_resolution: (res) =>
        if not res?
            bootbox.prompt "Change preview resolution from #{@get_resolution()} dpi to...", (result) =>
                if result
                    @set_resolution(result)
        else
            try
                res = parseInt(res)
                if res < 150
                    res = 150
                else if res > 600
                    res = 600
                @preview.opts.resolution = res
                @preview.update()
            catch e
                alert_message(type:"error", message:"Invalid resolution #{res}")

    get_resolution: () =>
        return @preview.opts.resolution


    click_save_button: () =>
        @latex_editor.click_save_button()

    save: (cb) =>
        @latex_editor.save (err) =>
            cb?(err)
            if not err
                @update_preview () =>
                    if @_current_page == 'pdf-preview'
                        @preview_embed.update()
                @spell_check()


    update_preview: (cb) =>
        @run_latex
            command : @load_conf_doc().latex_command
            cb      : () =>
                @preview.update
                    cb: (err) =>
                        cb?(err)

    _get: () =>
        return @latex_editor._get()

    _set: (content) =>
        @latex_editor._set(content)

    _show: (opts={}) =>
        if not @_split_pos?
            @_split_pos = .5
        @_split_pos = Math.max(MIN_SPLIT,Math.min(MAX_SPLIT, @_split_pos))

        @element.css(top:@editor.editor_top_position(), position:'fixed')
        @element.width($(window).width())

        width = @element.width()
        chat_pos = @element.find(".salvus-editor-codemirror-chat").offset()
        if chat_pos.left
            width = chat_pos.left

        {top, left} = @element.offset()
        editor_width = (width - left)*@_split_pos

        @_dragbar.css('left',editor_width+left)
        @latex_editor.show(width:editor_width)

        button_bar_height = @element.find(".salvus-editor-codemirror-button-container").height()

        @_right_pane_position =
            start : editor_width + left + 7
            end   : width
            top   : top + button_bar_height + 1

        if not @_show_before?
            @show_page('png-preview')
            @_show_before = true
        else
            @show_page()

        @_dragbar.height(@latex_editor.element.height()).css('top',button_bar_height+2)

    focus: () =>
        @latex_editor?.focus()

    has_unsaved_changes: (val) =>
        return @latex_editor?.has_unsaved_changes(val)

    show_page: (name) =>
        if not @_right_pane_position?
            return

        if not name?
            name = @_current_page
        @_current_page = name
        if not name?
            name = 'png-preview'

        pages = ['png-preview', 'pdf-preview', 'log', 'errors']
        for n in pages
            @element.find(".salvus-editor-latex-#{n}").hide()

        pos = @_right_pane_position
        g  = {left : pos.start, top:pos.top+3, width:pos.end-pos.start-3}
        if g.width < 50
            @element.find(".salvus-editor-latex-png-preview").find(".btn-group").hide()
            @element.find(".salvus-editor-latex-log").find(".btn-group").hide()
        else
            @element.find(".salvus-editor-latex-png-preview").find(".btn-group").show()
            @element.find(".salvus-editor-latex-log").find(".btn-group").show()

        for n in pages
            page = @_pages[n]
            if not page?
                continue
            e = @element.find(".salvus-editor-latex-#{n}")
            button = @element.find("a[href=#" + n + "]")
            if n == name
                e.show()
                if n not in ['log', 'errors']
                    page.show(g)
                else
                    page.offset({left:g.left, top:g.top}).width(g.width)
                    page.maxheight()
                    if n == 'log'
                        c = @load_conf_doc().latex_command
                        if c
                            @log_input.val(c)
                    else if n == 'errors'
                        @render_error_page()
                button.addClass('btn-primary')
            else
                button.removeClass('btn-primary')

    run_latex: (opts={}) =>
        opts = defaults opts,
            command : undefined
            cb      : undefined
        button = @element.find("a[href=#log]")
        button.icon_spin(true)
        log_output = @log.find("textarea")
        log_output.text("")
        if not opts.command?
            opts.command = @preview.pdflatex.default_tex_command()
        @log_input.val(opts.command)

        build_status = button.find(".salvus-latex-build-status")
        status = (mesg) =>
            if mesg.start
                build_status.text(' - ' + mesg.start)
                log_output.text(log_output.text() + '\n\n-----------------------------------------------------\nRunning ' + mesg.start + '...\n\n\n\n')
            else
                if mesg.end == 'latex'
                    @render_error_page()
                build_status.text('')
                log_output.text(log_output.text() + '\n' + mesg.log + '\n')
            # Scroll to the bottom of the textarea
            log_output.scrollTop(log_output[0].scrollHeight)

        @preview.pdflatex.update_pdf
            status        : status
            latex_command : opts.command
            cb            : (err, log) =>
                button.icon_spin(false)
                opts.cb?()

    render_error_page: () =>
        log = @preview.pdflatex.last_latex_log
        if not log?
            return
        p = (new LatexParser(log)).parse()

        if p.errors.length
            @number_of_errors.text(p.errors.length)
            @element.find("a[href=#errors]").addClass("btn-danger")
        else
            @number_of_errors.text('')
            @element.find("a[href=#errors]").removeClass("btn-danger")

        k = p.warnings.length + p.typesetting.length
        if k
            @number_of_warnings.text("(#{k})")
        else
            @number_of_warnings.text('')

        if @_current_page != 'errors'
            return

        elt = @errors.find(".salvus-latex-errors")
        if p.errors.length == 0
            elt.html("None")
        else
            elt.html("")
            cnt = 0
            for mesg in p.errors
                cnt += 1
                if cnt > MAX_LATEX_ERRORS
                    elt.append($("<h4>(Not showing #{p.errors.length - cnt + 1} additional errors.)</h4>"))
                    break
                elt.append(@render_error_message(mesg))

        elt = @errors.find(".salvus-latex-warnings")
        if p.warnings.length == 0
            elt.html("None")
        else
            elt.html("")
            cnt = 0
            for mesg in p.warnings
                cnt += 1
                if cnt > MAX_LATEX_WARNINGS
                    elt.append($("<h4>(Not showing #{p.warnings.length - cnt + 1} additional warnings.)</h4>"))
                    break
                elt.append(@render_error_message(mesg))

        elt = @errors.find(".salvus-latex-typesetting")
        if p.typesetting.length == 0
            elt.html("None")
        else
            elt.html("")
            cnt = 0
            for mesg in p.typesetting
                cnt += 1
                if cnt > MAX_LATEX_WARNINGS
                    elt.append($("<h4>(Not showing #{p.typesetting.length - cnt + 1} additional typesetting issues.)</h4>"))
                    break
                elt.append(@render_error_message(mesg))

    _show_error_in_file: (mesg, cb) =>
        file = mesg.file
        if not file
            alert_message(type:"error", "No way to open unknown file.")
            cb?()
            return
        if not mesg.line
            if mesg.page
                @_inverse_search
                    n : mesg.page
                    active : false
                    x : 50
                    y : 50
                    resolution:200
                    cb: cb
            else
                alert_message(type:"error", "Unknown location in '#{file}'.")
                cb?()
                return
        else
            if @preview.pdflatex.filename_tex == file
                @latex_editor.set_cursor_center_focus({line:mesg.line-1, ch:0})
            else
                if @_path # make relative to home directory of project
                    file = @_path + '/' + file
                @editor.open file, (err, fname) =>
                    if not err
                        @editor.display_tab(path:fname)
                        # TODO: need to set position, right?
                        # also, as in _inverse_search -- maybe this should be opened *inside* the latex editor...
            cb?()

    _show_error_in_preview: (mesg) =>
        if @preview.pdflatex.filename_tex == mesg.file
            @_show_error_in_file mesg, () =>
                @show_page('png-preview')
                @forward_search(active:true)

    render_error_message: (mesg) =>

        if not mesg.line
            r = mesg.raw
            i = r.lastIndexOf('[')
            j = i+1
            while j < r.length and r[j] >= '0' and r[j] <= '9'
                j += 1
            mesg.page = r.slice(i+1,j)

        if mesg.file.slice(0,2) == './'
            mesg.file = mesg.file.slice(2)

        elt = @_error_message_template.clone().show()
        elt.find("a:first").click () =>
            @_show_error_in_file(mesg)
            return false
        elt.find("a:last").click () =>
            @_show_error_in_preview(mesg)
            return false

        elt.addClass("salvus-editor-latex-mesg-template-#{mesg.level}")
        if mesg.line
            elt.find(".salvus-latex-mesg-line").text("line #{mesg.line}").data('line', mesg.line)
        if mesg.page
            elt.find(".salvus-latex-mesg-page").text("page #{mesg.page}").data('page', mesg.page)
        if mesg.file
            elt.find(".salvus-latex-mesg-file").text(" of #{mesg.file}").data('file', mesg.file)
        if mesg.message
            elt.find(".salvus-latex-mesg-message").text(mesg.message)
        if mesg.content
            elt.find(".salvus-latex-mesg-content").show().text(mesg.content)
        return elt


    download_pdf: () =>
        @editor.project_page.download_file
            path : @filename.slice(0,@filename.length-3) + "pdf"

    _inverse_search: (opts) =>
        active = opts.active  # whether user actively clicked, in which case we may open a new file -- otherwise don't open anything.
        delete opts.active
        cb = opts.cb
        opts.cb = (err, res) =>
            if err
                if active
                    alert_message(type:"error", message: "Inverse search error -- #{err}")
            else
                if res.input != @filename
                    if active
                        @editor.open res.input, (err, fname) =>
                            if not err
                                @editor.display_tab(path:fname)
                                # TODO: need to set position, right?
                else
                    @latex_editor.set_cursor_center_focus({line:res.line, ch:0})
            cb?()

        @preview.pdflatex.inverse_search(opts)

    inverse_search: (opts={}) =>
        opts = defaults opts,
            active : required
            cb     : undefined
        number = @preview.current_page().number
        elt    = @preview.pdflatex.page(number).element
        if not elt?
            opts.cb?("Preview not yet loaded.")
            return
        output = @preview.output
        nH     = elt.find("img")[0].naturalHeight
        y      = (output.height()/2 + output.offset().top - elt.offset().top) * nH / elt.height()
        @_inverse_search({n:number, x:0, y:y, resolution:@preview.pdflatex.page(number).resolution, cb:opts.cb})

    forward_search: (opts={}) =>
        opts = defaults opts,
            active : true
            cb     : undefined
        cm = @latex_editor.codemirror_with_last_focus
        if not cm?
            opts.cb?()
            return
        n = cm.getCursor().line + 1
        @preview.pdflatex.forward_search
            n  : n
            cb : (err, result) =>
                if err
                    if opts.active
                        alert_message(type:"error", message:err)
                else
                    y = result.y
                    pg = @preview.pdflatex.page(result.n)
                    res = pg.resolution
                    img = pg.element?.find("img")
                    if not img?
                        opts.cb?("Page #{result.n} not yet loaded.")
                        return
                    nH = img[0].naturalHeight
                    if not res?
                        y = 0
                    else
                        y *= res / 72 * img.height() / nH
                    @preview.scroll_into_view
                        n              : result.n
                        y              : y
                        highlight_line : true
                opts.cb?(err)





#############################################
# Viewer/editor (?) for history of changes to a document
#############################################

class HistoryEditor extends FileEditor
    constructor: (@editor, @filename, content, opts) ->
        opts.mode = ''

        @_parse_logstring_cache = {}
        @_parse_logstring_inverse_cache = {}

        # create history editor
        @element = templates.find(".salvus-editor-history").clone()
        @history_editor = codemirror_session_editor(@editor, @filename, opts)
        fname = misc.path_split(@filename).tail
        @ext = misc.filename_extension(fname[1..-14])

        @element.find(".salvus-editor-history-history_editor").append(@history_editor.element)
        @history_editor.codemirror.setOption("readOnly", true)
        @history_editor.show()

        if @ext == "sagews"
            opts0 =
                allow_javascript_eval : false
                static_viewer         : true
                read_only             : true
            @worksheet = new (syncdoc.SynchronizedWorksheet)(@history_editor, opts0)

        @slider = @element.find(".salvus-editor-history-slider")
        @forward_button = @element.find("a[href=#forward]")
        @back_button = @element.find("a[href=#back]")

        @init_history()

        @diffsync = new syncdoc.DiffSyncDoc
            cm          : @history_editor.codemirror
            readonly    : true

        @forward_button.click () =>
            if @forward_button.hasClass("disabled")
                return false
            @slider.slider("option", "value", @revision_num + 1)
            @goto_revision(@revision_num + 1)
            return false

        @back_button.click () =>
            if @back_button.hasClass("disabled")
                return false
            @slider.slider("option", "value", @revision_num - 1)
            @goto_revision(@revision_num - 1)
            return false

    init_history: () =>
        @element.find(".editor-btn-group").children().not(".btn-history").hide()
        @element.find(".salvus-editor-save-group").hide()
        @element.find(".salvus-editor-chat-title").hide()
        @element.find(".salvus-editor-history-controls").show()
        @slider.show()
        async.series([
            (cb) =>
                require('syncdoc').synchronized_string
                    project_id : @editor.project_id
                    filename   : @filename
                    cb         : (err, doc) =>
                        @file_history = doc
                        cb(err)
            (cb) =>
                @file_history.on 'sync', () =>
                    @render_history(false)
                @render_history(true)
        ])

    @revision_num = -1

    parse_logstring: (s) =>
        ##return JSON.parse(s)
        # In goto_revision below it looks like parse_logstring can get frequently called,
        # often on the same log entry repeatedly.  So we cache the parsing.
        obj = @_parse_logstring_cache[s]
        if obj?
            return obj
        try
            obj = JSON.parse(s)
            obj.patch = diffsync.decompress_patch_compat(obj.patch)
        catch e
            # It's better to do this than have the entire history become completely unusable.
            # Also, we should always *assume* any file can get corrupted.
            console.log("ERROR -- corrupt line in history -- '#{s}'")
            obj = {time:0, patch:[]}
        @_parse_logstring_cache[s] = obj
        return obj

    # same as parse_logstring above, but patch is replaced by its inverse
    parse_logstring_inverse: (s) =>
        ##obj = JSON.parse(s); diffsync.invert_patch_in_place(obj.patch)
        ##return obj
        # In goto_revision below it looks like parse_logstring can get frequently called,
        # often on the same log entry repeatedly.  So we cache the parsing.
        obj = @_parse_logstring_inverse_cache[s]
        if obj?
            return obj
        obj = misc.deep_copy(@parse_logstring(s))
        diffsync.invert_patch_in_place(obj.patch)
        @_parse_logstring_inverse_cache[s] = obj
        return obj

    goto_revision: (num) ->
        #t = misc.mswalltime()
        @element.find(".salvus-editor-history-revision-number").text("Revision " + num)
        if num == 0
            @element.find(".salvus-editor-history-revision-time").text("")
        else
            @element.find(".salvus-editor-history-revision-time").text(new Date(@parse_logstring(@log[@nlines-num+1]).time).toLocaleString())
        if @revision_num - num > 2
            #console.log("goto_revision #{num} from #{@revision_num}"); t = misc.mswalltime()
            text = @history_editor.codemirror.getValue()
            text_old = text
            #console.log("got value", misc.mswalltime(t)); t = misc.mswalltime()
            for patch in @log[(@nlines-@revision_num+1)..(@nlines-num)]
                text = diffsync.dmp.patch_apply(@parse_logstring(patch).patch, text)[0]
            #console.log("patched text", misc.mswalltime(t)); t = misc.mswalltime()
            @history_editor.codemirror.setValueNoJump(text)
            #console.log("changed editor", misc.mswalltime(t)); t = misc.mswalltime()
        else if @revision_num > num
            for patch in @log[(@nlines-@revision_num+1)..(@nlines-num)]
                @diffsync.patch_in_place(@parse_logstring(patch).patch)
        else if num - @revision_num > 2
            text = @history_editor.codemirror.getValue()
            text_old = text
            for patch in @log[(@nlines-num+1)..(@nlines-@revision_num)].reverse()
                text = diffsync.dmp.patch_apply(@parse_logstring_inverse(patch).patch, text)[0]
            @history_editor.codemirror.setValueNoJump(text)
        else
            for patch in @log[(@nlines-num+1)..(@nlines-@revision_num)].reverse()
                @diffsync.patch_in_place(@parse_logstring_inverse(patch).patch)
        @revision_num = num
        if @revision_num == 0
            @back_button.addClass("disabled")
        else
            @back_button.removeClass("disabled")
        if @revision_num == @nlines
            @forward_button.addClass("disabled")
        else
            @forward_button.removeClass("disabled")
        if @ext == 'sagews'
            @worksheet.process_sage_updates()
        #console.log("going to revision #{num} took #{misc.mswalltime(t)}ms")

    render_history: (first) =>
        @log = @file_history.live().split("\n")
        @nlines = @log.length - 1
        if first
            @element.find(".salvus-editor-history-revision-number").text("Revision " + @nlines)
            if @nlines == 0
                @element.find(".salvus-editor-history-revision-time").text("")
                @back_button.addClass("disabled")
            else
                @element.find(".salvus-editor-history-revision-time").text(new Date(@parse_logstring(@log[1]).time).toLocaleString())
            @history_editor.codemirror.setValue(JSON.parse(@log[0]))
            @revision_num = @nlines
            if @ext != "" and require('editor').file_associations[@ext].opts.mode?
                @history_editor.codemirror.setOption("mode", require('editor').file_associations[@ext].opts.mode)
            @slider.slider
                animate : false
                min     : 0
                max     : @nlines
                step    : 1
                value   : @revision_num
                slide  : (event, ui) =>
                    @goto_revision(ui.value)

        else
            @slider.slider
                max : @nlines
            @forward_button.removeClass("disabled")
        if @ext == 'sagews'
            @worksheet.process_sage_updates()

    show: () =>
        if not @is_active()
            return
        @element?.show()
        @history_editor?.show()
        if @ext == 'sagews'
            @worksheet.process_sage_updates()

class Terminal extends FileEditor
    constructor: (@editor, @filename, content, opts) ->
        @element = $("<div>").hide()
        elt = @element.salvus_console
            title     : "Terminal"
            filename  : filename
            resizable : false
            close     : () => @editor.project_page.display_tab("project-file-listing")
            editor    : @
        @console = elt.data("console")
        @element = @console.element
        salvus_client.read_text_file_from_project
            project_id : @editor.project_id
            path       : @filename
            cb         : (err, result) =>
                if err
                    alert_message(type:"error", message: "Error connecting to console server.")
                else
                    # New session or connect to session
                    if result.content? and result.content.length < 36
                        # empty/corrupted -- messed up by bug in early version of SMC...
                        delete result.content
                    opts = @opts = defaults opts,
                        session_uuid : result.content
                    @connect_to_server()

    connect_to_server: (cb) =>
        mesg =
            timeout    : 30  # just for making the connection; not the timeout of the session itself!
            type       : 'console'
            project_id : @editor.project_id
            cb : (err, session) =>
                if err
                    alert_message(type:'error', message:err)
                    cb?(err)
                else
                    if @element.is(":visible")
                        @show()
                    @console.set_session(session)
                    salvus_client.write_text_file_to_project
                        project_id : @editor.project_id
                        path       : @filename
                        content    : session.session_uuid
                        cb         : cb

        path = misc.path_split(@filename).head
        mesg.params  = {command:'bash', rows:@opts.rows, cols:@opts.cols, path:path}
        if @opts.session_uuid?
            mesg.session_uuid = @opts.session_uuid
            salvus_client.connect_to_session(mesg)
        else
            salvus_client.new_session(mesg)


    _get: () =>  # TODO
        return 'history saving not yet implemented'

    _set: (content) =>  # TODO

    focus: () =>
        @console?.focus()

    terminate_session: () =>

    remove: () =>
        @element.salvus_console(false)
        @element.remove()

    _show: () =>
        if @console?
            e = $(@console.terminal.element)
            top = @editor.editor_top_position() + @element.find(".salvus-console-topbar").height()
            # We leave a gap at the bottom of the screen, because often the
            # cursor is at the bottom, but tooltips, etc., would cover that
            ht = $(window).height() - top - 6
            if feature.isMobile.iOS()
                ht = Math.floor(ht/2)
            e.height(ht)
            @element.css(left:0, top:@editor.editor_top_position(), position:'fixed')   # TODO: this is hack-ish; needs to be redone!
            @console.focus(true)

class Image extends FileEditor
    constructor: (@editor, @filename, url, @opts) ->
        @element = templates.find(".salvus-editor-image").clone()
        @element.find(".salvus-editor-image-title").text(@filename)

        refresh = @element.find("a[href=#refresh]")
        refresh.click () =>
            refresh.icon_spin(true)
            @update (err) =>
                refresh.icon_spin(false)
            return false

        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

        if url?
            @element.find(".salvus-editor-image-container").find("span").hide()
            @element.find("img").attr('src', url)
        else
            @update()

    update: (cb) =>
        @element.find("a[href=#refresh]").icon_spin(start:true)
        salvus_client.read_file_from_project
            project_id : @editor.project_id
            timeout    : 30
            path       : @filename
            cb         : (err, mesg) =>
                @element.find("a[href=#refresh]").icon_spin(false)
                @element.find(".salvus-editor-image-container").find("span").hide()
                if err
                    alert_message(type:"error", message:"Communications issue loading #{@filename} -- #{err}")
                    cb?(err)
                else if mesg.event == 'error'
                    alert_message(type:"error", message:"Error getting #{@filename} -- #{to_json(mesg.error)}")
                    cb?(mesg.event)
                else
                    @element.find("img").attr('src', mesg.url + "?random=#{Math.random()}")
                    cb?()

    show: () =>
        if not @is_active()
            return
        @element.show()
        @element.css(top:@editor.editor_top_position())
        @element.maxheight()



class StaticHTML extends FileEditor
    constructor: (@editor, @filename, @content, opts) ->
        @element = templates.find(".salvus-editor-static-html").clone()
        @init_buttons()

    show: () =>
        if not @is_active()
            return
        if not @iframe?
            @iframe = @element.find(".salvus-editor-static-html-content").find('iframe')
            # We do this, since otherwise just loading the iframe using
            #      @iframe.contents().find('html').html(@content)
            # messes up the parent html page...
            @iframe.contents().find('body')[0].innerHTML = @content
            @iframe.contents().find('body').find("a").attr('target','_blank')
        @element.show()
        @element.css(top:@editor.editor_top_position())
        @element.maxheight(offset:18)
        @iframe.maxheight()

    init_buttons: () =>
        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

class IPythonNBViewer extends FileEditor
    constructor: (@editor, @filename, @content, opts) ->
        @element = templates.find(".salvus-editor-ipython-nbviewer").clone()
        @init_buttons()

    show: () =>
        if not @is_active()
            return
        @element.show()
        if not @iframe?
            @iframe = @element.find(".salvus-editor-ipython-nbviewer-content").find('iframe')
            # We do this, since otherwise just loading the iframe using
            #      @iframe.contents().find('html').html(@content)
            # messes up the parent html page, e.g., foo.modal() is gone.
            @iframe.contents().find('body')[0].innerHTML = @content

        @element.css(top:@editor.editor_top_position())
        @element.maxheight(offset:18)
        @element.find(".salvus-editor-ipython-nbviewer-content").maxheight(offset:18)
        @iframe.maxheight(offset:18)

    init_buttons: () =>
        @element.find("a[href=#copy]").click () =>
            ipynb_filename = @filename.slice(0,@filename.length-4) + 'ipynb'
            @editor.project_page.copy_to_another_project_dialog ipynb_filename, false, (err, x) =>
                console.log("x=#{misc.to_json(x)}")
                if not err
                    require('projects').open_project
                        project   : x.project_id
                        target    : "files/" + x.path
                        switch_to : true
            return false

        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false


#**************************************************
# IPython Support
#**************************************************

ipython_notebook_server = (opts) ->
    opts = defaults opts,
        project_id : required
        path       : '.'   # directory from which the files are served -- default to home directory of project
        cb         : required   # cb(err, server)

    I = new IPythonNotebookServer(opts.project_id, opts.path)
    I.start_server (err, base) =>
        opts.cb(err, I)

class IPythonNotebookServer  # call ipython_notebook_server above
    constructor: (@project_id, @path) ->

    start_server: (cb) =>
        #console.log("start_server")
        salvus_client.exec
            project_id : @project_id
            path       : @path
            command    : "ipython-notebook"
            args       : ['start']
            bash       : false
            timeout    : 30
            err_on_exit: false
            cb         : (err, output) =>
                if err
                    cb?(err)
                else
                    try
                        info = misc.from_json(output.stdout)
                        if info.error?
                            cb?(info.error)
                        else
                            @url = info.base; @pid = info.pid; @port = info.port
                            get_with_retry
                                url : @url
                                cb  : (err, data) =>
                                    cb?(err)
                    catch e
                        cb?(true)

    stop_server: (cb) =>
        if not @pid?
            cb?(); return
        salvus_client.exec
            project_id : @project_id
            path       : @path
            command    : "ipython-notebook"
            args       : ['stop']
            bash       : false
            timeout    : 15
            cb         : (err, output) =>
                cb?(err)

# Download a remote URL, possibly retrying repeatedly with exponential backoff
# on the timeout.
# If the downlaod URL contains bad_string (default: 'ECONNREFUSED'), also retry.
get_with_retry = (opts) ->
    opts = defaults opts,
        url           : required
        initial_timeout : 5000
        max_timeout     : 15000     # once delay hits this, give up
        factor        : 1.1     # for exponential backoff
        bad_string    : 'ECONNREFUSED'
        cb            : required  # cb(err, data)  # data = content of that url
    timeout = opts.initial_timeout
    delay   = 50
    f = () =>
        if timeout >= opts.max_timeout  # too many attempts
            opts.cb("unable to connect to remote server")
            return
        $.ajax(
            url     : opts.url
            timeout : timeout
            success : (data) ->
                if data.indexOf(opts.bad_string) != -1
                    timeout *= opts.factor
                    setTimeout(f, delay)
                else
                    opts.cb(false, data)
        ).fail(() ->
            timeout *= opts.factor
            delay   *= opts.factor
            setTimeout(f, delay)
        )

    f()


# Embedded editor for editing IPython notebooks.  Enhanced with sync and integrated into the
# overall cloud look.
class IPythonNotebook extends FileEditor
    constructor: (@editor, @filename, url, opts) ->
        opts = @opts = defaults opts,
            sync_interval : 500
            cursor_interval : 2000
        @element = templates.find(".salvus-ipython-notebook").clone()

        @_start_time = misc.walltime()
        if window.salvus_base_url != ""
            # TODO: having a base_url doesn't imply necessarily that we're in a dangerous devel mode...
            # (this is just a warning).
            # The solutiion for this issue will be to set a password whenever ipython listens on localhost.
            @element.find(".salvus-ipython-notebook-danger").show()
            setTimeout( ( () => @element.find(".salvus-ipython-notebook-danger").hide() ), 3000)

        @status_element = @element.find(".salvus-ipython-notebook-status-messages")
        @init_buttons()
        s = path_split(@filename)
        @path = s.head
        @file = s.tail

        if @path
            @syncdoc_filename = @path + '/.' + @file + ".syncdoc"
        else
            @syncdoc_filename = '.' + @file + ".syncdoc"

        # This is where we put the page itself
        @notebook = @element.find(".salvus-ipython-notebook-notebook")
        @con = @element.find(".salvus-ipython-notebook-connecting")
        @setup () =>
            # TODO: We have to do this stupid thing because in IPython's notebook.js they don't systematically use
            # set_dirty, sometimes instead just directly seting the flag.  So there's no simple way to know exactly
            # when the notebook is dirty. (TODO: fix all this via upstream patches.)
            # Also, note there are cases where IPython doesn't set the dirty flag
            # even though the output has changed.   For example, if you type "123" in a cell, run, then
            # comment out the line and shift-enter again, the empty output doesn't get sync'd out until you do
            # something else.  If any output appears then the dirty happens.  I guess this is a bug that should be fixed in ipython.
            @_autosync_interval = setInterval(@autosync, @opts.sync_interval)
            @_cursor_interval = setInterval(@broadcast_cursor_pos, @opts.cursor_interval)

    status: (text) =>
        if not text?
            text = ""
        else if false
            text += " (started at #{Math.round(misc.walltime(@_start_time))}s)"
        @status_element.html(text)

    setup: (cb) =>
        if @_setting_up
            cb?("already setting up")
            return  # already setting up
        @_setting_up = true
        @con.show().icon_spin(start:true)
        delete @_cursors   # Delete all the cached cursors in the DOM
        delete @nb
        delete @frame

        async.series([
            (cb) =>
                @status("Checking whether ipynb file has changed...")
                salvus_client.exec
                    project_id : @editor.project_id
                    path       : @path
                    command    : "stat"   # %Z below = time of last change, seconds since Epoch; use this not %Y since often users put file in place, but with old time
                    args       : ['--printf', '%Z ', @file, @syncdoc_filename]
                    timeout    : 15
                    err_on_exit: false
                    cb         : (err, output) =>
                        if err
                            cb(err)
                        else if output.stderr.indexOf('such file or directory') != -1
                            # nothing to do -- the syncdoc file doesn't even exist.
                            cb()
                        else
                            v = output.stdout.split(' ')
                            if parseInt(v[0]) >= parseInt(v[1]) + 10
                                @_use_disk_file = true
                            cb()
            (cb) =>
                @status("Ensuring synchronization file exists")
                @editor.project_page.ensure_file_exists
                    path  : @syncdoc_filename
                    alert : false
                    cb    : (err) =>
                        if err
                            # unable to create syncdoc file -- open in non-sync read-only mode.
                            @readonly = true
                        else
                            @readonly = false
                        #console.log("ipython: readonly=#{@readonly}")
                        cb()
            (cb) =>
                @initialize(cb)
            (cb) =>
                if @readonly
                    # TODO -- change UI to say *READONLY*
                    @iframe.css(opacity:1)
                    @save_button.text('Readonly').addClass('disabled')
                    @show()
                    cb()
                else
                    @_init_doc(cb)
                    @init_autosave()
        ], (err) =>
            @con.show().icon_spin(false).hide()
            @_setting_up = false
            if err
                @save_button.addClass("disabled")
                @status("Failed to start -- #{err}")
                cb?("Unable to start IPython server -- #{err}")
            else
                cb?()
        )

    _init_doc: (cb) =>
        #console.log("_init_doc: connecting to sync session")
        @status("Connecting to synchronized editing session...")
        if @doc?
            # already initialized
            @doc.sync () =>
                @set_live_from_syncdoc()
                @iframe.css(opacity:1)
                @show()
                cb?()
            return
        @doc = syncdoc.synchronized_string
            project_id : @editor.project_id
            filename   : @syncdoc_filename
            sync_interval : @opts.sync_interval
            cb         : (err) =>
                #console.log("_init_doc returned: err=#{err}")
                @status()
                if err
                    cb?("Unable to connect to synchronized document server -- #{err}")
                else
                    if @_use_disk_file
                        @doc.live('')
                    @_config_doc()
                    cb?()

    _config_doc: () =>
        #console.log("_config_doc")
        # todo -- should check if .ipynb file is newer... ?
        @status("Displaying IPython Notebook")
        if @doc.live() == ''
            @doc.live(@to_doc())
        else
            @set_live_from_syncdoc()
        #console.log("DONE SETTING!")
        @iframe.css(opacity:1)
        @show()

        @doc._presync = () =>
            if not @nb? or @_reloading
                # no point -- reinitializing the notebook frame right now...
                return
            @doc.live(@to_doc())

        apply_edits = @doc.dsync_client._apply_edits_to_live

        apply_edits2 = (patch, cb) =>
            #console.log("_apply_edits_to_live ")#-- #{JSON.stringify(patch)}")
            before =  @to_doc()
            if not before?
                cb?("reloading")
                return
            @doc.dsync_client.live = before
            apply_edits(patch)
            if @doc.dsync_client.live != before
                @from_doc(@doc.dsync_client.live)
                #console.log("edits should now be applied!")#, @doc.dsync_client.live)
            cb?()

        @doc.dsync_client._apply_edits_to_live = apply_edits2

        @doc.on "reconnect", () =>
            if not @doc.dsync_client?
                # this could be an older connect emit that didn't get handled -- ignore.
                return
            apply_edits = @doc.dsync_client._apply_edits_to_live
            @doc.dsync_client._apply_edits_to_live = apply_edits2
            # Update the live document with the edits that we missed when offline
            @status("Reconnecting and updating live document...")
            @from_doc(@doc.dsync_client.live)
            @status()

        # TODO: we should just create a class that derives from SynchronizedString at this point.
        @doc.draw_other_cursor = (pos, color, name) =>
            if not @_cursors?
                @_cursors = {}
            id = color + name
            cursor_data = @_cursors[id]
            if not cursor_data?
                if not @frame?.$?
                    # do nothing in case initialization is incomplete
                    return
                cursor = templates.find(".salvus-editor-codemirror-cursor").clone().show()
                # craziness -- now move it into the iframe!
                cursor = @frame.$("<div>").html(cursor.html())
                cursor.css(position: 'absolute', width:'15em')
                inside = cursor.find(".salvus-editor-codemirror-cursor-inside")
                inside.css
                    'background-color': color
                    position : 'absolute'
                    top : '-1.3em'
                    left: '.5ex'
                    height : '1.15em'
                    width  : '.1ex'
                    'border-left': '2px solid black'
                    border  : '1px solid #aaa'
                    opacity :'.7'

                label = cursor.find(".salvus-editor-codemirror-cursor-label")
                label.css
                    color:'color'
                    position:'absolute'
                    top:'-2.3em'
                    left:'1.5ex'
                    'font-size':'8pt'
                    'font-family':'serif'
                    'z-index':10000
                label.text(name)
                cursor_data = {cursor: cursor, pos:pos}
                @_cursors[id] = cursor_data
            else
                cursor_data.pos = pos

            # first fade the label out
            cursor_data.cursor.find(".salvus-editor-codemirror-cursor-label").stop().show().animate(opacity:1).fadeOut(duration:16000)
            # Then fade the cursor out (a non-active cursor is a waste of space).
            cursor_data.cursor.stop().show().animate(opacity:1).fadeOut(duration:60000)
            @nb?.get_cell(pos.index)?.code_mirror.addWidget(
                      {line:pos.line,ch:pos.ch}, cursor_data.cursor[0], false)
        @status()


    broadcast_cursor_pos: () =>
        if not @nb? or @readonly
            # no point -- reloading or loading or read-only
            return
        index = @nb.get_selected_index()
        cell  = @nb.get_cell(index)
        if not cell?
            return
        pos   = cell.code_mirror.getCursor()
        s = misc.to_json(pos)
        if s != @_last_cursor_pos
            @_last_cursor_pos = s
            @doc.broadcast_cursor_pos(index:index, line:pos.line, ch:pos.ch)

    remove: () =>
        if @_sync_check_interval?
            clearInterval(@_sync_check_interval)
        if @_cursor_interval?
            clearInterval(@_cursor_interval)
        if @_autosync_interval?
            clearInterval(@_autosync_interval)
        if @_reconnect_interval?
            clearInterval(@_reconnect_interval)
        @element.remove()
        @doc?.disconnect_from_session()
        @_dead = true

    initialize: (cb) =>
        async.series([
            (cb) =>
                @status("Connecting to your IPython Notebook server")
                ipython_notebook_server
                    project_id : @editor.project_id
                    cb         : (err, server) =>
                        @server = server
                        cb(err)
            (cb) =>
                @_init_iframe(cb)
        ], cb)

    # Initialize the embedded iframe and wait until the notebook object in it is initialized.
    # If this returns (calls cb) without an error, then the @nb attribute must be defined.
    _init_iframe: (cb) =>
        @status("Rendering IPython notebook")
        get_with_retry
            url : @server.url
            cb  : (err) =>
                if err
                    @status()
                    #console.log("exit _init_iframe 2")
                    cb(err); return
                @iframe_uuid = misc.uuid()

                @status("Loading IPython notebook...")

                @iframe = $("<iframe name=#{@iframe_uuid} id=#{@iframe_uuid}>").css('opacity','.01').attr('src', "#{@server.url}notebooks/#{@filename}")
                @notebook.html('').append(@iframe)
                @show()

                # Monkey patch the IPython html so clicking on the IPython logo pops up a new tab with the dashboard,
                # instead of messing up our embedded view.
                attempts = 0
                delay = 200
                start_time = misc.walltime()
                # What f does below is purely inside the browser DOM -- not the network, so doing it frequently is not a serious
                # problem for the server.
                f = () =>
                    #console.log("(attempt #{attempts}, time #{misc.walltime(start_time)}): @frame.ipython=#{@frame?.IPython?}, notebook = #{@frame?.IPython?.notebook?}, kernel= #{@frame?.IPython?.notebook?.kernel?}")
                    if @_dead?
                        cb("dead"); return
                    attempts += 1
                    if delay <= 750  # exponential backoff up to 300ms.
                        delay *= 1.2
                    if attempts >= 80
                        # give up after this much time.
                        msg = "Failed to load IPython notebook"
                        @status(msg)
                        #console.log("exit _init_iframe 3")
                        cb(msg)
                        return
                    @frame = window.frames[@iframe_uuid]
                    if not @frame? or not @frame?.$? or not @frame.IPython? or not @frame.IPython.notebook? or not @frame.IPython.notebook.kernel?
                        setTimeout(f, delay)
                    else
                        a = @frame.$("#ipython_notebook").find("a")
                        if a.length == 0
                            setTimeout(f, delay)
                        else
                            @ipython = @frame.IPython
                            if not @ipython.notebook?
                                msg = "BUG -- Something went wrong -- notebook object not defined in IPython frame"
                                @status(msg)
                                #console.log("exit _init_iframe 4")
                                cb(msg)
                                return
                            @nb = @ipython.notebook

                            a.click () =>
                                @info()
                                return false

                            # Replace the IPython Notebook logo, which is for some weird reason an ugly png, with proper HTML; this ensures the size
                            # and color match everything else.
                            a.html('<span style="font-size: 18pt;"><span style="color:black">IP</span>[<span style="color:black">y</span>]: Notebook</span>')

                            # proper file rename with sync not supported yet (but will be -- TODO; needs to work with sync system)
                            @frame.$("#notebook_name").unbind('click').css("line-height",'0em')

                            # Get rid of file menu, which weirdly and wrongly for sync replicates everything.
                            for cmd in ['new', 'open', 'copy', 'rename']
                                @frame.$("#" + cmd + "_notebook").remove()
                            @frame.$("#kill_and_exit").remove()
                            @frame.$("#menus").find("li:first").find(".divider").remove()

                            @frame.$('<style type=text/css></style>').html(".container{width:98%; margin-left: 0;}").appendTo(@frame.$("body"))
                            @nb._save_checkpoint = @nb.save_checkpoint
                            @nb.save_checkpoint = @save

                            if @readonly
                                @frame.$("#save_widget").append($("<b style='background: red;color: white;padding-left: 1ex; padding-right: 1ex;'>This is a READONLY document that can't be saved.</b>"))

                            # Ipython doesn't consider a load (e.g., snapshot restore) "dirty" (for obvious reasons!)
                            @nb._load_notebook_success = @nb.load_notebook_success
                            @nb.load_notebook_success = (data,status,xhr) =>
                                @nb._load_notebook_success(data,status,xhr)
                                @sync()

                            # Periodically reconnect the IPython websocket.  This is LAME to have to do, but if I don't do this,
                            # then the thing hangs and reconnecting then doesn't work (the user has to do a full frame refresh).
                            # TODO: understand this and fix it properly.  This is entirely related to the complicated proxy server
                            # stuff in SMC, not sync!
                            websocket_reconnect = () =>
                                @nb?.kernel?.start_channels()
                            @_reconnect_interval = setInterval(websocket_reconnect, 60000)

                            @status()
                            cb()

                setTimeout(f, delay)

    # although highly unlikely, this could happen if something else steals our port before we can restart...
    check_for_moved_server: () =>
        if @nb?.kernel?  # only try if nb is already loaded
            if not @nb.kernel.shell_channel   # if backend is gone/replaced, then this would get set to null
                ipython_notebook_server
                    project_id : @editor.project_id
                    path       : @path
                    cb         : (err, server) =>
                        if err
                            # nothing to be done.
                            return
                        if server.url != @server.url
                            # server moved!?
                            @server = server
                            @reload() # -- only thing we can do, really

    autosync: () =>
        if @readonly
            return
        @check_for_moved_server()  # only bother if document being changed.
        if @frame?.IPython?.notebook?.dirty and not @_reloading
            #console.log("causing sync")
            @save_button.removeClass('disabled')
            @sync()
            @nb.dirty = false

    sync: () =>
        if @readonly
            return
        @activity_indicator()
        @save_button.icon_spin(start:true,delay:1000)
        @doc.sync () =>
            @save_button.icon_spin(false)

    has_unsaved_changes: () =>
        return not @save_button.hasClass('disabled')

    save: (cb) =>
        if not @nb? or @readonly
            cb?(); return
        @save_button.icon_spin(start:true, delay:1000)
        @nb._save_checkpoint?()
        @doc.save () =>
            @save_button.icon_spin(false)
            @save_button.addClass('disabled')
            cb?()

    set_live_from_syncdoc: () =>
        if not @doc?.dsync_client?  # could be re-initializing
            return
        current = @to_doc()
        if not current?
            return
        if @doc.dsync_client.live != current
            @from_doc(@doc.dsync_client.live)

    info: () =>
        t = "<h3>The IPython Notebook</h3>"
        t += "<h4>Enhanced with SageMathCloud Sync</h4>"
        t += "You are editing this document using the IPython Notebook enhanced with realtime synchronization."
        t += "<h4>Use Sage by pasting this into a cell</h4>"
        t += "<pre>%load_ext sage</pre>"
        #t += "<h4>Connect to this IPython kernel in a terminal</h4>"
        #t += "<pre>ipython console --existing #{@kernel_id}</pre>"
        t += "<h4>Pure IPython notebooks</h4>"
        if @server?.url?
            t += "You can <a target='_blank' href='#{@server.url}notebooks/#{@filename}'>open this notebook in a vanilla IPython Notebook server without sync</a> (this link works only for project collaborators).  "
        #t += "<br><br>To start your own unmodified IPython Notebook server that is securely accessible to collaborators, type in a terminal <br><br><pre>ipython-notebook run</pre>"
        t += "<h4>Known Issues</h4>"
        t += "If two people edit the same <i>cell</i> simultaneously, the cursor will jump to the start of the cell."
        bootbox.alert(t)
        return false

    reload: () =>
        if @_reloading
            return
        @_reloading = true
        @_cursors = {}
        @reload_button.find("i").addClass('fa-spin')
        @initialize (err) =>
            @_init_doc () =>
                @_reloading = false
                @status('')
                @reload_button.find("i").removeClass('fa-spin')

    init_buttons: () =>
        @element.find("a").tooltip(delay:{show: 500, hide: 100})
        @save_button = @element.find("a[href=#save]").click () =>
            @save()
            return false

        @reload_button = @element.find("a[href=#reload]").click () =>
            @reload()
            return false

        @publish_button = @element.find("a[href=#publish]").click () =>
            @publish_ui()
            return false

        #@element.find("a[href=#json]").click () =>
        #    console.log(@to_obj())

        @element.find("a[href=#info]").click () =>
            @info()
            return false

        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

        @element.find("a[href=#execute]").click () =>
            @nb?.execute_selected_cell()
            return false
        @element.find("a[href=#interrupt]").click () =>
            @nb?.kernel.interrupt()
            return false
        @element.find("a[href=#tab]").click () =>
            @nb?.get_cell(@nb?.get_selected_index()).completer.startCompletion()
            return false

    publish_ui: () =>
        url = document.URL
        url = url.slice(0,url.length-5) + 'html'
        dialog = templates.find(".salvus-ipython-publish-dialog").clone()
        dialog.modal('show')
        dialog.find(".btn-close").off('click').click () ->
            dialog.modal('hide')
            return false
        status = (mesg, percent) =>
            dialog.find(".salvus-ipython-publish-status").text(mesg)
            p = "#{percent}%"
            dialog.find(".progress-bar").css('width',p).text(p)

        @publish status, (err) =>
            dialog.find(".salvus-ipython-publish-dialog-publishing")
            if err
                dialog.find(".salvus-ipython-publish-dialog-fail").show().find('span').text(err)
            else
                dialog.find(".salvus-ipython-publish-dialog-success").show()
                url_box = dialog.find(".salvus-ipython-publish-url")
                url_box.val(url)
                url_box.click () ->
                    $(this).select()

    publish: (status, cb) =>
        #d = (m) => console.log("ipython.publish('#{@filename}'): #{misc.to_json(m)}")
        #d()
        @publish_button.find("fa-refresh").show()
        async.series([
            (cb) =>
                status?("saving",0)
                @save(cb)
            (cb) =>
                status?("running nbconvert",30)
                @nbconvert
                    format : 'html'
                    cb     : (err) =>
                        cb(err)
            (cb) =>
                status?("making '#{@filename}' public", 70)
                @editor.project_page.publish_path
                    path        : @filename
                    description : "IPython notebook #{@filename}"
                    cb          : cb
            (cb) =>
                html = @filename.slice(0,@filename.length-5)+'html'
                status?("making '#{html}' public", 90)
                @editor.project_page.publish_path
                    path        : html
                    description : "IPython html version of #{@filename}"
                    cb          : cb
        ], (err) =>
            status?("done", 100)
            @publish_button.find("fa-refresh").hide()
            cb?(err)
        )

    nbconvert: (opts) =>
        opts = defaults opts,
            format : required
            cb     : undefined
        salvus_client.exec
            path        : @path
            project_id  : @editor.project_id
            command     : 'ipython'
            args        : ['nbconvert', @file, "--to=#{opts.format}"]
            bash        : false
            err_on_exit : true
            timeout     : 30
            cb          : (err, output) =>
                console.log("nbconvert finished with err='#{err}, ouptut='#{misc.to_json(output)}'")
                opts.cb?(err)

    # WARNING: Do not call this before @nb is defined!
    to_obj: () =>
        #console.log("to_obj: start"); t = misc.mswalltime()
        if not @nb?
            # can't get obj
            return undefined
        obj = @nb.toJSON()
        obj.metadata.name  = @nb.notebook_name
        obj.nbformat       = @nb.nbformat
        obj.nbformat_minor = @nb.nbformat_minor
        #console.log("to_obj: done", misc.mswalltime(t))
        return obj

    from_obj: (obj) =>
        #console.log("from_obj: start"); t = misc.mswalltime()
        if not @nb?
            return
        i = @nb.get_selected_index()
        st = @nb.element.scrollTop()
        @nb.fromJSON(obj)
        @nb.dirty = false
        @nb.select(i)
        @nb.element.scrollTop(st)
        #console.log("from_obj: done", misc.mswalltime(t))

    # Notebook Doc Format: line 0 is meta information in JSON; one line with the JSON of each cell for reset of file
    to_doc: () =>
        #console.log("to_doc: start"); t = misc.mswalltime()
        obj = @to_obj()
        if not obj?
            return
        doc = misc.to_json({notebook_name:obj.metadata.name})
        for cell in obj.worksheets[0].cells
            doc += '\n' + misc.to_json(cell)
        #console.log("to_doc: done", misc.mswalltime(t))
        return doc

    ###
    # simplistic version of modifying the notebook in place.  VERY slow when new cell added.
    from_doc0: (doc) =>
        #console.log("from_doc: start"); t = misc.mswalltime()
        nb = @nb
        v = doc.split('\n')
        nb.metadata.name  = v[0].notebook_name
        cells = []
        for line in v.slice(1)
            try
                c = misc.from_json(line)
                cells.push(c)
            catch e
                console.log("error de-jsoning '#{line}'", e)
        obj = @to_obj()
        obj.worksheets[0].cells = cells
        @from_obj(obj)
        console.log("from_doc: done", misc.mswalltime(t))
    ###

    delete_cell: (index) =>
        @nb?.delete_cell(index)

    insert_cell: (index, cell_data) =>
        if not @nb?
            return
        new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
        new_cell.fromJSON(cell_data)

    set_cell: (index, cell_data) =>
        #console.log("set_cell: start"); t = misc.mswalltime()
        if not @nb?
            return

        cell = @nb.get_cell(index)

        if cell? and cell_data.cell_type == cell.cell_type
            #console.log("setting in place")

            if cell.output_area?
                # for some reason fromJSON doesn't clear the output (it should, imho), and the clear_output method
                # on the output_area doesn't work as expected.
                wrapper = cell.output_area.wrapper
                wrapper.empty()
                cell.output_area = new @ipython.OutputArea(wrapper, true)

            cell.fromJSON(cell_data)

            ###  for debugging that we properly update a cell in place -- if this is wrong,
            #    all hell breaks loose, and sync loops ensue.
            a = misc.to_json(cell_data)
            b = misc.to_json(cell.toJSON())
            if a != b
                console.log("didn't work:")
                console.log(a)
                console.log(b)
                @nb.delete_cell(index)
                new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
                new_cell.fromJSON(cell_data)
            ###

        else
            #console.log("replacing")
            @nb.delete_cell(index)
            new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
            new_cell.fromJSON(cell_data)
        #console.log("set_cell: done", misc.mswalltime(t))

    ###
    # simplistic version of setting from doc; *very* slow on cell insert.
    from_doc0: (doc) =>
        console.log("goal='#{doc}'")
        console.log("live='#{@to_doc()}'")

        console.log("from_doc: start"); t = misc.mswalltime()
        goal = doc.split('\n')
        live = @to_doc().split('\n')

        @nb.metadata.name  = goal[0].notebook_name

        for i in [1...Math.max(goal.length, live.length)]
            index = i-1
            if i >= goal.length
                console.log("deleting cell #{index}")
                @nb.delete_cell(index)
            else if goal[i] != live[i]
                console.log("replacing cell #{index}")
                try
                    cell_data = JSON.parse(goal[i])
                    @set_cell(index, cell_data)
                catch e
                    console.log("error de-jsoning '#{goal[i]}'", e)

        console.log("from_doc: done", misc.mswalltime(t))
    ###

    from_doc: (doc) =>
        #console.log("goal='#{doc}'")
        #console.log("live='#{@to_doc()}'")
        #console.log("from_doc: start"); tm = misc.mswalltime()
        if not @nb?
            # The live notebook is not currently initialized -- there's nothing to be done for now.
            # This can happen if reconnect (to hub) happens at the same time that user is reloading
            # the ipython notebook frame itself.   The doc will get set properly at the end of the
            # reload anyways, so no need to set it here.
            return

        goal = doc.split('\n')
        live = @to_doc()?.split('\n')
        if not live?
            # reloading...
            return
        @nb.metadata.name  = goal[0].notebook_name

        v0    = live.slice(1)
        v1    = goal.slice(1)
        string_mapping = new misc.StringCharMapping()
        v0_string  = string_mapping.to_string(v0)
        v1_string  = string_mapping.to_string(v1)
        diff = diffsync.dmp.diff_main(v0_string, v1_string)

        index = 0
        i = 0

        parse = (s) ->
            try
                return JSON.parse(s)
            catch e
                console.log("UNABLE to parse '#{s}' -- not changing this cell.")

        #console.log("diff=#{misc.to_json(diff)}")
        i = 0
        while i < diff.length
            chunk = diff[i]
            op    = chunk[0]  # -1 = delete, 0 = leave unchanged, 1 = insert
            val   = chunk[1]
            if op == 0
                # skip over  cells
                index += val.length
            else if op == -1
                # delete  cells:
                # A common special case arises when one is editing a single cell, which gets represented
                # here as deleting then inserting.  Replacing is far more efficient than delete and add,
                # due to the overhead of creating codemirror instances (presumably).  (Also, there is a
                # chance to maintain the cursor later.)
                if i < diff.length - 1 and diff[i+1][0] == 1 and diff[i+1][1].length == val.length
                    #console.log("replace")
                    for x in diff[i+1][1]
                        obj = parse(string_mapping._to_string[x])
                        if obj?
                            @set_cell(index, obj)
                        index += 1
                    i += 1 # skip over next chunk
                else
                    #console.log("delete")
                    for j in [0...val.length]
                        @delete_cell(index)
            else if op == 1
                # insert new cells
                #console.log("insert")
                for x in val
                    obj = parse(string_mapping._to_string[x])
                    if obj?
                        @insert_cell(index, obj)
                    index += 1
            else
                console.log("BUG -- invalid diff!", diff)
            i += 1

        #console.log("from_doc: done", misc.mswalltime(tm))
        #if @to_doc() != doc
        #    console.log("FAIL!")
        #    console.log("goal='#{doc}'")
        #    console.log("live='#{@to_doc()}'")
        #    @from_doc0(doc)

    focus: () =>
        # TODO
        # console.log("ipython notebook focus: todo")

    show: () =>
        if not @is_active()
            return
        @element.show()
        top = @editor.editor_top_position()
        @element.css(top:top)
        if top == 0
            @element.css('position':'fixed')
        w = $(window).width()
        # console.log("top=#{top}; setting maxheight for iframe =", @iframe)
        @iframe?.attr('width',w).maxheight()
        setTimeout((()=>@iframe?.maxheight()), 1)   # set it one time more the next render loop.

class FileEditorWrapper extends FileEditor
    constructor: (@editor, @filename) ->
        @init_wrapped()
        @init_autosave()

    init_wrapped: () =>
        # Define @element and @wrapped in derived class
        throw "must define in derived class"

    save: () =>
        @wrapped.save?()

    has_unsaved_changes: (val) =>
        return @wrapped.has_unsaved_changes?(val)

    _get: () =>
        # TODO
        return 'history saving not yet implemented'

    _set: (content) =>
        # TODO

    focus: () =>

    terminate_session: () =>

    disconnect_from_session: () =>
        @wrapped.destroy?()

    remove: () =>
        @element.remove()
        @wrapped.destroy?()

    show: () =>
        if not @is_active()
            return
        @element.show()
        if not IS_MOBILE
            @element.css(top:@editor.editor_top_position(), position:'fixed')
        else
            # TODO: this is a terrible HACK for position the top of the editor.
            @element.closest(".salvus-editor-content").css(position:'relative', top:'0')
            @element.css(position:'relative', top:'0')
        @wrapped.show?()

    hide: () =>
        @element.hide()
        @wrapped.hide?()

###
# Task list
###

tasks = require('tasks')

class TaskList extends FileEditorWrapper
    init_wrapped: () ->
        @element = tasks.task_list(@editor.project_id, @filename, @)
        @wrapped = @element.data('task_list')

###
# A Course one is managing (or taking?)
###
course = require('course')

class Course extends FileEditorWrapper
    init_wrapped: () ->
        @element = course.course(@editor, @filename)
        @wrapped = @element.data('course')


#############################################
# Editor for HTML/Markdown/ReST documents
#############################################

class HTML_MD_Editor extends FileEditor
    constructor: (@editor, @filename, content, @opts) ->
        # The are two components, side by side
        #     * source editor -- a CodeMirror editor
        #     * preview/contenteditable -- rendered view
        @ext = filename_extension(@filename)   #'html' or 'md'

        if @ext == 'html'
            @opts.mode = 'htmlmixed'
        else if @ext == 'md'
            @opts.mode = 'gfm'
        else if @ext == 'rst'
            @opts.mode = 'rst'
        else if @ext == 'wiki' or @ext == "mediawiki"
            # canonicalize .wiki and .mediawiki (as used on github!) to "mediawiki"
            @ext = "mediawiki"
            @opts.mode = 'mediawiki'
        else if @ext == 'tex'  # for testing/experimentation
            @opts.mode = 'stex2'
        else
            throw "file must have extension md or html or rst or wiki or tex"

        @disable_preview = @local_storage("disable_preview")

        @element = templates.find(".salvus-editor-html-md").clone()

        # create the textedit button bar.
        @edit_buttons = templates.find(".salvus-editor-textedit-buttonbar").clone()
        @element.find(".salvus-editor-html-md-textedit-buttonbar").append(@edit_buttons)

        @preview = @element.find(".salvus-editor-html-md-preview")
        @preview_content = @preview.find(".salvus-editor-html-md-preview-content")

        # initialize the codemirror editor
        @source_editor = codemirror_session_editor(@editor, @filename, @opts)
        @element.find(".salvus-editor-html-md-source-editor").append(@source_editor.element)
        @source_editor.action_key = @action_key

        @spell_check()

        cm = @cm()
        cm.on('change', @update_preview)
        #cm.on 'cursorActivity', @update_preview

        @init_buttons()
        @init_draggable_split()

        @init_preview_select()

        @init_keybindings()

        # this is entirely because of the chat
        # currently being part of @source_editor, and
        # only calling the show for that; once chat
        # is refactored out, delete this.
        @source_editor.on 'show-chat', () =>
            @show()
        @source_editor.on 'hide-chat', () =>
            @show()

    cm: () =>
        return @source_editor.syncdoc.focused_codemirror()

    init_keybindings: () =>
        keybindings =  # inspired by http://www.door2windows.com/list-of-all-keyboard-shortcuts-for-sticky-notes-in-windows-7/
            bold      : 'Cmd-B Ctrl-B'
            italic    : 'Cmd-I Ctrl-I'
            underline : 'Cmd-U Ctrl-U'
            comment   : 'Shift-Ctrl-3'
            strikethrough : 'Shift-Cmd-X Shift-Ctrl-X'
            justifycenter : "Cmd-E Ctrl-E"
            #justifyright  : "Cmd-R Ctrl-R"  # messes up page reload
            subscript     : "Cmd-= Ctrl-="
            superscript   : "Shift-Cmd-= Shift-Ctrl-="

        extra_keys = @cm().getOption("extraKeys") # current keybindings
        if not extra_keys?
            extra_keys = {}
        for cmd, keys of keybindings
            for k in keys.split(' ')
                ( (cmd) => extra_keys[k] = (cm) => @command(cm, cmd) )(cmd)

        for cm in @source_editor.codemirrors()
            cm.setOption("extraKeys", extra_keys)

    init_draggable_split: () =>
        @_split_pos = @local_storage("split_pos")
        @_dragbar = dragbar = @element.find(".salvus-editor-html-md-resize-bar")
        dragbar.css(position:'absolute')
        dragbar.draggable
            axis : 'x'
            containment : @element
            zIndex      : 100
            stop        : (event, ui) =>
                # compute the position of bar as a number from 0 to 1
                left  = @element.offset().left
                chat_pos = @element.find(".salvus-editor-codemirror-chat").offset()
                if chat_pos.left
                    width = chat_pos.left - left
                else
                    width = @element.width()
                p     = dragbar.offset().left
                @_split_pos = (p - left) / width
                @local_storage('split_pos', @_split_pos)
                @show()

    inverse_search: (cb) =>

    forward_search: (cb) =>

    action_key: () =>

    remove: () =>
        @element.remove()

    init_buttons: () =>
        @element.find("a").tooltip(delay:{ show: 500, hide: 100 } )
        @element.find("a[href=#save]").click(@click_save_button)
        @print_button = @element.find("a[href=#print]").show().click(@print)
        @init_edit_buttons()
        @init_preview_buttons()

    command: (cm, cmd, args) =>
        switch cmd
            when "link"
                cm.insert_link()
            when "image"
                cm.insert_image()
            when "SpecialChar"
                cm.insert_special_char()
            else
                cm.edit_selection
                    cmd  : cmd
                    args : args
                    mode : @opts.mode
                @sync()

    init_preview_buttons: () =>
        disable = @element.find("a[href=#disable-preview]").click () =>
            disable.hide()
            enable.show()
            @disable_preview = true
            @local_storage("disable_preview", true)
            @preview_content.html('')

        enable = @element.find("a[href=#enable-preview]").click () =>
            disable.show()
            enable.hide()
            @disable_preview = false
            @local_storage("disable_preview", false)
            @update_preview()

        if @disable_preview
            enable.show()
            disable.hide()

    init_edit_buttons: () =>
        that = @
        @edit_buttons.find("a").click () ->
            args = $(this).data('args')
            cmd  = $(this).attr('href').slice(1)
            if args? and typeof(args) != 'object'
                args = "#{args}"
                if args.indexOf(',') != -1
                    args = args.split(',')
            that.command(that.cm(), cmd, args)
            return false

        if true #  @ext != 'html'
            # hide some buttons, since these are not markdown friendly operations:
            for t in ['clean'] # I don't like this!
                @edit_buttons.find("a[href=##{t}]").hide()

        # initialize the color controls
        button_bar = @edit_buttons
        init_color_control = () =>
            elt   = button_bar.find(".sagews-output-editor-foreground-color-selector")
            if IS_MOBILE
                elt.hide()
                return
            button_bar_input = elt.find("input").colorpicker()
            sample = elt.find("i")
            set = (hex, init) =>
                sample.css("color", hex)
                button_bar_input.css("background-color", hex)
                if not init
                    @command(@cm(), "color", hex)

            button_bar_input.change (ev) =>
                hex = button_bar_input.val()
                set(hex)

            button_bar_input.on "changeColor", (ev) =>
                hex = ev.color.toHex()
                set(hex)

            sample.click (ev) =>
                button_bar_input.colorpicker('show')

            set("#000000", true)

        init_color_control()
        # initialize the color control
        init_background_color_control = () =>
            elt   = button_bar.find(".sagews-output-editor-background-color-selector")
            if IS_MOBILE
                elt.hide()
                return
            button_bar_input = elt.find("input").colorpicker()
            sample = elt.find("i")
            set = (hex, init) =>
                button_bar_input.css("background-color", hex)
                elt.find(".input-group-addon").css("background-color", hex)
                if not init
                    @command(@cm(), "background-color", hex)

            button_bar_input.change (ev) =>
                hex = button_bar_input.val()
                set(hex)

            button_bar_input.on "changeColor", (ev) =>
                hex = ev.color.toHex()
                set(hex)

            sample.click (ev) =>
                button_bar_input.colorpicker('show')

            set("#fff8bd", true)

        init_background_color_control()

    print: () =>
        if @_printing
            return
        @_printing = true
        @print_button.icon_spin(start:true, delay:0).addClass("disabled")
        @convert_to_pdf (err, output) =>
            @_printing = false
            @print_button.removeClass('disabled')
            @print_button.icon_spin(false)
            if err
                alert_message(type:"error", message:"Printing error -- #{err}")
            else
                salvus_client.read_file_from_project
                    project_id : @editor.project_id
                    path       : output.filename
                    cb         : (err, mesg) =>
                        if err
                            cb(err)
                        else
                            url = mesg.url + "?nocache=#{Math.random()}"
                            window.open(url,'_blank')

    convert_to_pdf: (cb) =>  # cb(err, {stdout:?, stderr:?, filename:?})
        s = path_split(@filename)
        target = s.tail + '.pdf'
        if @ext in ['md', 'html', 'rst', 'mediawiki']
            # pandoc --latex-engine=xelatex a.wiki -o a.pdf
            command = 'pandoc'
            args    = ['--latex-engine=xelatex', s.tail, '-o', target]
            bash = false
        else if @ext == 'tex'
            t = "." + misc.uuid()
            command = "mkdir -p #{t}; xelatex -output-directory=#{t} '#{s.tail}'; mv '#{t}/*.pdf' '#{target}'; rm -rf #{t}"
            bash = true

        target = @filename + ".pdf"
        output = undefined
        async.series([
            (cb) =>
                @save(cb)
            (cb) =>
                salvus_client.exec
                    project_id  : @editor.project_id
                    command     : command
                    args        : args
                    err_on_exit : true
                    bash        : bash
                    path        : s.head
                    cb          : (err, o) =>
                        console.log("convert_to_pdf output ", err, output)
                        if err
                            cb(err)
                        else
                            output = o
                            cb()
        ], (err) =>
            if err
                cb?(err)
            else
                output.filename = @filename + ".pdf"
                cb?(undefined, output)
        )

    misspelled_words: (opts) =>
        opts = defaults opts,
            lang : undefined
            cb   : required
        if not opts.lang?
            opts.lang = misc_page.language()
        if opts.lang == 'disable'
            opts.cb(undefined,[])
            return
        if @ext == "html"
            mode = "html"
        else if @ext == "tex"
            mode = 'tex'
        else
            mode = 'none'
        #t0 = misc.mswalltime()
        salvus_client.exec
            project_id  : @editor.project_id
            command     : "cat '#{@filename}'|aspell --mode=#{mode} --lang=#{opts.lang} list|sort|uniq"
            bash        : true
            err_on_exit : true
            cb          : (err, output) =>
                #console.log("spell_check time: #{misc.mswalltime(t0)}ms")
                if err
                    opts.cb(err); return
                if output.stderr
                    opts.cb(output.stderr); return
                opts.cb(undefined, output.stdout.slice(0,output.stdout.length-1).split('\n'))  # have to slice final \n

    spell_check: () =>
        @misspelled_words
            cb : (err, words) =>
                if err
                    return
                else
                    for cm in @source_editor.codemirrors()
                        cm.spellcheck_highlight(words)

    has_unsaved_changes: () =>
        return @source_editor.has_unsaved_changes()

    save: (cb) =>
        @source_editor.syncdoc.save (err) =>
            if not err
                @spell_check()
            cb?(err)

    sync: (cb) =>
        @source_editor.syncdoc.sync(cb)

    outside_tag: (line, i) ->
        left = line.slice(0,i)
        j = left.lastIndexOf('>')
        k = left.lastIndexOf('<')
        if k > j
            return k
        else
            return i

    file_path: () =>
        if not @_file_path?
            @_file_path = misc.path_split(@filename).head
        return @_file_path

    to_html: (cb) =>
        f = @["#{@ext}_to_html"]
        if f?
            f(cb)
        else
            @to_html_via_pandoc(cb:cb)

    html_to_html: (cb) =>   # cb(error, {source:?, mathjax:?})  where mathjax is true/false
        # add in cursor(s)
        source = @source_editor._get()
        cm = @source_editor.syncdoc.focused_codemirror()
        # figure out where pos is in the source and put HTML cursor there
        lines = source.split('\n')
        markers =
            cursor : "\uFE22"
            from   : "\uFE23"
            to     : "\uFE24"

        if @ext == 'html'
            for s in cm.listSelections()
                if s.empty()
                    # a single cursor
                    pos = s.head
                    line = lines[pos.line]
                    # TODO: for now, tags have to start/end on a single line
                    i = @outside_tag(line, pos.ch)
                    lines[pos.line] = line.slice(0,i)+markers.cursor+line.slice(i)
                else if false  # disable
                    # a selection range
                    to = s.to()
                    line = lines[to.line]
                    to.ch = @outside_tag(line, to.ch)
                    i = to.ch
                    lines[to.line] = line.slice(0,i) + markers.to + line.slice(i)

                    from = s.from()
                    line = lines[from.line]
                    from.ch = @outside_tag(line, from.ch)
                    i = from.ch
                    lines[from.line] = line.slice(0,i) + markers.from + line.slice(i)

        if @ext == 'html'
            # embed position data by putting invisible spans before each element.
            for i in [0...lines.length]
                line = lines[i]
                line2 = ''
                for j in [0...line.length]
                    if line[j] == "<"  # TODO: worry about < in mathjax...
                        s = line.slice(0,j)
                        c = s.split(markers.cursor).length + s.split(markers.from).length + s.split(markers.to).length - 3  # TODO: ridiculously inefficient
                        line2 = "<span data-line=#{i} data-ch=#{j-c} class='smc-pos'></span>" + line.slice(j) + line2
                        line = line.slice(0,j)
                lines[i] = "<span data-line=#{i} data-ch=0 class='smc-pos'></span>"+line + line2

        source = lines.join('\n')

        source = misc.replace_all(source, markers.cursor, "<span class='smc-html-cursor'></span>")

        # add smc-html-selection class to everything that is selected
        # TODO: this will *only* work when there is one range selection!!
        i = source.indexOf(markers.from)
        j = source.indexOf(markers.to)
        if i != -1 and j != -1
            elt = $("<span>")
            elt.html(source.slice(i+1,j))
            elt.find('*').addClass('smc-html-selection')
            source = source.slice(0,i) + "<span class='smc-html-selection'>" + elt.html() + "</span>" + source.slice(j+1)

        cb(undefined, {html:source, mathjax:true}) # TODO: mathjax

    md_to_html: (cb) =>
        source = @source_editor._get()
        m = misc_page.markdown_to_html(source)
        cb(undefined, {html:m.s, mathjax:m.has_mathjax})

    rst_to_html: (cb) =>
        @to_html_via_exec
            command     : "rst2html"
            args        : [@filename]
            cb          : cb

    to_html_via_pandoc: (opts) =>
        opts.command = "pandoc"
        opts.args = ["--toc", "-t", "html", '--highlight-style', 'pygments', @filename]
        @to_html_via_exec(opts)

    to_html_via_exec: (opts) =>
        opts = defaults opts,
            command     : required
            args        : required
            postprocess : undefined
            cb          : required   # cb(error, {html:?, mathjax:?})
        html = undefined
        warnings = undefined
        async.series([
            (cb) =>
                @save(cb)
            (cb) =>
                salvus_client.exec
                    project_id  : @editor.project_id
                    command     : opts.command
                    args        : opts.args
                    err_on_exit : false
                    cb          : (err, output) =>
                        #console.log("salvus_client.exec ", err, output)
                        if err
                            cb(err)
                        else
                            html = output.stdout
                            warnings = output.stderr
                            cb()
        ], (err) =>
            if err
                opts.cb(err)
            else
                if opts.postprocess?
                    html = opts.postprocess(html)
                opts.cb(undefined, {html:html, mathjax:true, warnings:warnings})
        )

    update_preview: () =>
        if @disable_preview
            return

        if @_update_preview_lock
            @_update_preview_redo = true
            return

        t0 = misc.mswalltime()
        @_update_preview_lock = true
        #console.log("update_preview")
        @to_html (err, r) =>
            @_update_preview_lock = false
            if err
                console.log("failed to render preview: #{err}")
                return
            source = r.html

            # remove any javascript and make html more sane
            elt = $("<span>").html(source)
            elt.find('script').remove()
            elt.find('link').remove()
            source = elt.html()

            # finally set html in the live DOM
            @preview_content.html(source)

            @localize_image_links(@preview_content)

            ## this would disable clickable links...
            #@preview.find("a").click () =>
            #    return false
            # Make it so preview links can be clicked, don't close SMC page.
            @preview_content.find("a").attr("target","_blank")
            @preview_content.find("table").addClass('table')  # bootstrap table

            if r.mathjax
                @preview_content.mathjax()

            #@preview_content.find(".smc-html-cursor").scrollintoview()
            #@preview_content.find(".smc-html-cursor").remove()

            #console.log("update_preview time=#{misc.mswalltime(t0)}ms")
            if @_update_preview_redo
                @_update_preview_redo = false
                @update_preview()

    localize_image_links: (e) =>
        # make relative links to images use the raw server
        for x in e.find("img")
            y = $(x)
            src = y.attr('src')
            if not src? or src[0] == '/' or src.indexOf('://') != -1
                continue
            new_src = "/#{@editor.project_id}/raw/#{@file_path()}/#{src}"
            y.attr('src', new_src)
        # make relative links to objects use the raw server
        for x in e.find("object")
            y = $(x)
            src = y.attr('data')
            if not src? or src[0] == '/' or src.indexOf('://') != -1
                continue
            new_src = "/#{@editor.project_id}/raw/#{@file_path()}/#{src}"
            y.attr('data', new_src)

    init_preview_select: () =>
        @preview_content.click (evt) =>
            sel = window.getSelection()
            if @ext=='html'
                p = $(evt.target).prevAll(".smc-pos:first")
            else
                p = $(evt.target).nextAll(".smc-pos:first")

            #console.log("evt.target after ", p)
            if p.length == 0
                if @ext=='html'
                    p = $(sel.anchorNode).prevAll(".smc-pos:first")
                else
                    p = $(sel.anchorNode).nextAll(".smc-pos:first")
                #console.log("anchorNode after ", p)
            if p.length == 0
                console.log("clicked but not able to determine position")
                return
            pos = p.data()
            #console.log("p.data=#{misc.to_json(pos)}, focusOffset=#{sel.focusOffset}")
            if not pos?
                pos = {ch:0, line:0}
            pos = {ch:pos.ch + sel.focusOffset, line:pos.line}
            #console.log("clicked on ", pos)
            @cm().setCursor(pos)
            @cm().scrollIntoView(pos.line)
            @cm().focus()

    _get: () =>
        return @source_editor._get()

    _set: (content) =>
        @source_editor._set(content)

    _show: (opts={}) =>
        if not @_split_pos?
            @_split_pos = .5
        @_split_pos = Math.max(MIN_SPLIT,Math.min(MAX_SPLIT, @_split_pos))
        @element.css(top:@editor.editor_top_position(), position:'fixed')
        @element.width($(window).width())

        width = @element.width()
        chat_pos = @element.find(".salvus-editor-codemirror-chat").offset()
        if chat_pos.left
            width = chat_pos.left

        {top, left} = @element.offset()
        editor_width = (width - left)*@_split_pos

        @_dragbar.css('left',editor_width+left)

        @source_editor.show
            width : editor_width
            top   : top + @edit_buttons.height()

        button_bar_height = @element.find(".salvus-editor-codemirror-button-container").height()
        @element.maxheight(offset:button_bar_height)
        @preview.maxheight(offset:button_bar_height)

        @_dragbar.height(@source_editor.element.height())
        @_dragbar.css('top',top-9)  # -9 = ugly hack

        # position the preview
        @preview.css
            left  : editor_width + left + 7
            width : width - (editor_width + left + 7)
            top   : top


    focus: () =>
        @source_editor?.focus()


