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
#  top_navbar -- the top level navbar
#########################################################################

{salvus_client} = require('salvus_client')


$(document).on 'keydown', (ev) =>
    if (ev.metaKey or ev.ctrlKey) and ev.keyCode == 79    # ctrl (or meta) o.
        #console.log("document keydown ", ev)
        return false

misc = require("misc")
misc_page = require('misc_page')
to_json = misc.to_json
defaults = misc.defaults
required = defaults.required
{EventEmitter} = require('events')

class TopNavbar  extends EventEmitter

    constructor: () ->
        @pages            = {}
        @navbar           = $(".salvus-top_navbar")
        @buttons          = @navbar.find("ul.nav.pull-left.buttons")   # the list of buttons on the left
        @projects         = @navbar.find("ul.nav.pull-left.projects")
        @buttons_right    = @navbar.find("ul.nav.pull-right")  # the list of buttons on the right
        @button_template  = $(".top_navbar-button-template")
        @divider_template = $("#top_navbar-divider-template")

    add_page: (opts) ->
        opts = defaults opts,
            page          : undefined  # jQuery wrapped DOM element -- if not given, you probably want to define onshow!
            id            : required   # id that client code uses to refer to this page; need not be a DOM id.
            label         : required   # jquery object that is placed in the button
            'class'       : undefined  # classes to apply to label
            insert_after  : undefined  # if given, the page is inserted after the page with given id.
            insert_before : undefined  # if given, the page is inserted before the page with given id.
            pull_right    : false      # if true, place button in the right-hand side group of buttons.
            close         : true       # if true, include a "close" x.
            onclose       : undefined  # called if defined when the page is closed
            onshow        : undefined  # called if defined right after page is shown
            onblur        : undefined  # called if defined right after page is blured
            onfullscreen  : undefined  # called with onfullscreen(true or false) when switching to fullscreen (true) or out (false).
            icon          : undefined  # something like 'fa-globe'
            icon_img      : undefined  # alternatively (if icon is not set), a path for an <img src=""> icon

        button  = @button_template.clone()
        divider = @divider_template.clone()
        if opts.pull_right
            @buttons_right.prepend(button)
            #button.before(divider)
        else if opts.id.length == 36
            @projects.append(button)
            #button.after(divider)
        else
            @buttons.append(button)
        @pages[opts.id] =
            page         : opts.page
            button       : button
            onclose      : opts.onclose
            onshow       : opts.onshow
            onblur       : opts.onblur
            onfullscreen : opts.onfullscreen
            divider      : divider
            icon         : opts.icon
            icon_img     : opts.icon_img

        a = button.find("a")
        a.data("id", opts.id)
        that = @
        a.click((event) -> that.switch_to_page($(this).data("id")); return false)

        @set_button_label(opts.id, opts.label, opts.class, opts.icon, opts.icon_img, opts.close)

    number_of_pages_left: () =>
        return @buttons.children().length / 2   # /2 because of dividers

    number_of_pages_right: () =>
        return @buttons_right.children().length  # /2 because of dividers

    set_button_label: (id, label, klass, icon, icon_img, close=true) ->
        if not icon? and @pages[id].icon?
            icon = @pages[id].icon
        button = @pages[id].button
        a = button.find("a")
        a.find(".button-label").text(label)
        if icon?
            a.find(".button-label").prepend($("<i class='fa #{icon}' style='font-size:20px;padding-right: 2px;'> </i>"))
        else if icon_img?
            a.find(".button-label").prepend($("<img>").attr("src", icon_img))
        close_button = a.find(".close-button")
        if close
            close_button.data("id", id)
            that = @
            close_button.click((event) -> that.remove_page($(this).data("id")); return false)
        else
            close_button.hide()
        if klass?
            a.find(".button-label").addClass(klass)
            #a.addClass(klass)

    switch_to_page: (id) ->
        if not id?
            id = @current_page_id

        n = @pages[id]
        if not n?
            return

        if id != @current_page_id
            for m, p of @pages
                if m != id
                    p.page?.hide()
                    p.button.removeClass("active")
            d = @pages[@current_page_id]
            if d?
                @emit("switch_from_page-#{@current_page_id}", @current_page_id)
                d.onblur?()
            n.button.show().addClass("active")
            @current_page_id = id
            @emit("switch_to_page-#{id}", id)

        # We still call show even if already on this page.
        n.page?.show()
        n.onshow?()
        ga('send', 'pageview', window.location.pathname)

    activity_indicator: (id) =>
        if not id?
            id = @current_page_id
        e = @pages[id]?.button
        if not e?
            return
        if not @_activity_indicator_timers?
            @_activity_indicator_timers = {}
        timer = @_activity_indicator_timers[id]
        if timer?
            clearTimeout(timer)
        e.find("i:last").addClass("salvus-top_navbar-tab-active")
        f = () ->
            e.find("i:last").removeClass("salvus-top_navbar-tab-active")
        @_activity_indicator_timers[id] = setTimeout(f, 1000)

    fullscreen: (entering) =>
        @pages[@current_page_id]?.onfullscreen?(entering)

    make_button_active: (id) ->
        @pages[id]?.button.addClass("active")

    switch_to_next_available_page: (id) ->
        #console.log('switch_to_next_available_page',id)
        # Switch to the next page after the page
        # with given id, unless there is no such page,
        # in which case, switch to the previous page.
        # This is used, e.g., when closing a tab to select a new tab.
        # This will never select the *settings tab*.
        p = @pages[id]
        next_button = p.button.next()
        next = next_button.find("a")
        nid = next.data('id')
        if nid?
            @switch_to_page(nid)
        else
            @switch_to_prev_available_page(id)

    switch_to_prev_available_page: (id) ->
        # There is always a previous page, because of the project page.
        #console.log("switch_to_prev_available_page")
        p = @pages[id]
        prev_button = p.button.prev()
        if prev_button.length == 0
            @switch_to_page('projects')
            return
        prev = prev_button.find("a")
        id = prev.data('id')
        if id?
            @switch_to_page(id)


    # entirely remove the page
    remove_page: (id) ->
        p = @pages[id]
        if p?
            if p.onclose?
                # save unsaved work, etc.
                p.onclose()
            if p.button.hasClass("active")
                @switch_to_next_available_page(id)
            # Now actually the page
            p.page?.remove()
            p.button.remove()
            p.divider.remove()
            delete @pages[id]

            @resize_open_project_tabs()
            # Now switch to the next page

    # make it so the navbar entry to go to a given page is hidden
    hide_page_button: (id) ->
        @pages[id]?.button.hide()

    # make it so the navbar entry to go to a given page is shown
    show_page_button: (id) ->
        @pages[id]?.button.show()

    # TODO -- ?
    have_unsaved_changes: (id) ->
        return false

    # Makes the project list sortable by the user
    init_sortable_project_list: () =>
        if @_project_list_is_sortable
            return
        @navbar.find(".nav.projects").sortable
            axis                 : 'x'
            delay                : 50
            containment          : 'parent'
            tolerance            : 'pointer'
            placeholder          : 'nav-projects-placeholder'
            forcePlaceholderSize : true
        @_project_list_is_sortable = true

    destroy_sortable_project_list: () =>
        if not @_project_list_is_sortable
            return
        @navbar.find(".nav.projects").sortable("destroy")
        @_project_list_is_sortable = false

    resize_open_project_tabs: () =>
        # Make a list of the open project tabs
        x = @projects.find("li")
        if x.length == 0
            return

        if misc_page.is_responsive_mode()
            # responsive mode
            @destroy_sortable_project_list()
            width = "100%"
        else
            @init_sortable_project_list()
            n = x.length
            width = Math.min(200, (@projects.width() - 25)/n) # subtract to prevent rounding problems
            if width < 0
                width = 0
        for a in x
            $(a).width(width)

top_navbar = exports.top_navbar = new TopNavbar()


# Make a jQuery plugin for adding dom objects to top navbar
$.fn.extend
    top_navbar: (opts) ->
        return @each () ->
            opts.page = $(this)
            top_navbar.add_page(opts)


###############################################################
# Add the standard pages

$("#salvus-help").top_navbar
    id      : "salvus-help"
    label   : "Help"
    icon    : 'fa-question-circle'
    pull_right : true
    close   : false
    onshow: () -> misc_page.set_window_title("Help")



###
$("#about").top_navbar
    id      : "about"
    label   : "SageMathCloud&trade;"
    #label : ''
    icon : 'fa-cloud'
    #pull_right : true
    close   : false
###

###
$(".salvus-explore").top_navbar
    id      : "explorer"
    label   : "Explore"
    icon : 'fa-globe'
    close   : false
###

$("#projects").top_navbar
    id      : "projects"
    #'class' : 'navbar-big'
    label   : "Projects"
    #icon : 'fa-tasks'
    icon_img: '/favicon-195.png'
    close   : false
    onshow: () -> misc_page.set_window_title("Projects")

$("#account").top_navbar
    id     : "account"
    label  : "Account"
    pull_right : true
    close   : false
    icon : 'fa-signin'
    onshow: () -> misc_page.set_window_title("Account")

#$("#worksheet2").top_navbar
#    id      : "worksheet2"
#    label   : "Worksheet2"
#    close   : false

#$("#worksheet1").top_navbar
#    id      : "worksheet1"
#    label   : "Worksheet1"
#    close   : false


$(window).resize () ->
    $("body").css
        'padding-top': ($(".salvus-top_navbar").height()) + 1 + 'px'
    top_navbar.resize_open_project_tabs()

$(".salvus-fullscreen-activate").click () ->
    salvus_client.in_fullscreen_mode(true)
    $(".salvus-fullscreen-activate").hide()
    $(".salvus-fullscreen-deactivate").show()
    $(".salvus-top_navbar").hide()
    top_navbar.fullscreen(true)
    $("body").css('padding-top':0)
    return false

$(".salvus-fullscreen-deactivate").click () ->
    salvus_client.in_fullscreen_mode(false)
    $(".salvus-fullscreen-activate").show()
    $(".salvus-fullscreen-deactivate").hide()
    $(".salvus-top_navbar").show()
    top_navbar.fullscreen(false)
    $("body").css('padding-top': ($(".salvus-top_navbar").height()) + 1 + 'px')
    return false

$(".salvus-connection-status-ping-time").tooltip(delay:{ show: 500, hide: 100 })