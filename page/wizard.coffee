###############################################################################
#
#    SageMathCloud: A collaborative web-based interface to Sage, IPython, LaTeX and the Terminal.
#
#    Copyright (C) 2015, SageMathCloud Authors
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

"use strict"
_ = require("underscore")
{defaults, required} = require('misc')
misc_page = require('misc_page')

wizard_template = $(".smc-wizard")

data = null

class Wizard
    constructor: (opts) ->
        @opts = defaults opts,
            lang  : 'sage'

        @dialog = wizard_template.clone()

        # the elements
        @nav      = @dialog.find(".smc-wizard-nav")
        @lvl1     = @dialog.find(".smc-wizard-lvl1")
        @lvl2     = @dialog.find(".smc-wizard-lvl2")
        @document = @dialog.find(".smc-wizard-doc")
        @code     = @dialog.find(".smc-wizard-code")
        @descr    = @dialog.find(".smc-wizard-descr > div.panel-body")

        # the state
        @lang     = @opts.lang
        @cat1     = undefined
        @cat2     = undefined
        @title    = undefined
        @doc      = undefined

        @init()
        @dialog.modal('show')

    init: () =>
        cb = () =>
            @init_nav()
            @init_buttons()
            @init_lvl1()

        if data?
            # console.log "data exists"
            cb()
        else
            # console.log "data null"
            $.ajax # TODO use some of those clever retry-functions
                url: window.salvus_base_url + "/static/wizard/wizard.js"
                dataType: "json"
                error: (jqXHR, textStatus, errorThrown) =>
                    console.log "AJAX Error: #{textStatus}"
                success: (data2, textStatus, jqXHR) =>
                    # console.log "Successful AJAX call: #{data}"
                    data = data2
                    cb()

    init_nav: () ->
        # <li role="presentation"><a href="#sage">Sage</a></li>
        nav_entries = [
            ["sage", "Sage"],
            ["python", "Python"],
            ["r", "R"],
            ["gap", "GAP"],
            ["cython", "Cython"]]
        for entry, idx in nav_entries when data[entry[0]]?
            @nav.append($("<li role='presentation'><a href='##{entry[0]}'>#{entry[1]}</a></li>"))
            if @opts.lang == entry[0]
                @set_active(@nav, @nav.children(idx))

    init_lvl1: () ->
        if @opts.lang?
            @fill_list(@lvl1, data[@opts.lang])

    init_buttons: () ->
        @dialog.find(".btn-close").on "click", =>
            @dialog.modal('hide')
            return false

        @dialog.find(".btn-submit").on "click", =>
            @submit()
            return false

        @nav.on "click", "li", (evt) =>
            #evt.preventDefault()
            pill = $(evt.target)
            @select_nav(pill)
            return false

        @lvl1.on "click", "li", (evt) =>
            #evt.preventDefault()
            # .closest("li") because of the badge
            t = $(evt.target).closest("li")
            @select_lvl1(t)
            return false

        @lvl2.on "click", "li", (evt) =>
            #evt.preventDefault()
            t = $(evt.target).closest("li")
            @select_lvl2(t)
            return false

        @document.on "click", "li", (evt) =>
            #evt.preventDefault()
            t = $(evt.target)
            @select_doc(t)
            return false

        @dialog.on "keydown", (evt) =>
            # 38: up,   40: down  /  74: j-key, 75: k-key
            # 37: left, 39: right /  72: h-key, 76: l-key
            # jQuery's prev/next need a check for length to see, if there is an element
            # necessary, since it is an unevaluated jquery object?
            key = evt.which
            active = @document.find(".active")
            if not active? || key not in [13, 38, 40, 74, 75, 37, 39, 72, 76]
                return
            evt.preventDefault()
            if key == 13 # return
                @submit()
            else if key in [38, 40, 74, 75] # up or down
                if key in [38, 75] # up
                    dirop = "prev"
                    carryop = "last"

                else if key in [40, 74] # down
                    dirop = "next"
                    carryop = "first"

                new_doc = active[dirop]()
                if new_doc.length == 0
                    # we have to switch back one step in the lvl2 category
                    lvl2_active = @lvl2.find(".active")
                    new_lvl2 = lvl2_active[dirop]()
                    if new_lvl2.length == 0
                        lvl1_active = @lvl1.find(".active")
                        # now, we also have to step back in the highest lvl1 category
                        new_lvl1 = lvl1_active[dirop]()
                        if new_lvl1.length == 0
                            new_lvl1 = @lvl1.children()[carryop]()
                        @select_lvl1(new_lvl1)
                        new_lvl2 = @lvl2.children()[carryop]()
                    @select_lvl2(new_lvl2)
                    new_doc = @document.children()[carryop]()
                @select_doc(new_doc)

            else # left or right
                if key in [37, 72] # left
                    new_pill = @nav.find(".active").prev()
                    if new_pill.length == 0
                        new_pill = @nav.children().last()
                else if key in [39, 76] # right
                    new_pill = @nav.find(".active").next()
                    if new_pill.length == 0
                        new_pill = @nav.children().first()
                @select_nav(new_pill.children(0))

    submit: () ->
        @dialog.modal('hide')
        window.alert("INSERT CODE:\n" + @doc[0])

    set_active: (list, which) ->
        list.find("li").removeClass("active")
        which.addClass("active")

    select_nav: (pill) ->
        @set_active(@nav, pill.parent())
        @lang = pill.attr("href").substring(1)
        @lvl2.empty()
        @document.empty()
        @fill_list(@lvl1, data[@lang])

    select_lvl1: (t) ->
        @set_active(@lvl1, t)
        @cat1 = t.attr("data")
        # console.log("lvl1: #{select1}")
        @document.empty()
        @fill_list(@lvl2, data[@lang][@cat1])
        @scroll_visible(@lvl1, t)

    select_lvl2: (t) ->
        @set_active(@lvl2, t)
        @cat2 = t.attr("data")
        # console.log("lvl2: #{select2}")
        @fill_list(@document, data[@lang][@cat1][@cat2])
        @scroll_visible(@lvl2, t)

    select_doc: (t) ->
        @set_active(@document, t)
        @title = t.attr("data")
        @doc = data[@lang][@cat1][@cat2][@title]
        @code.text(@doc[0])
        @descr.html(misc_page.markdown_to_html(@doc[1]).s)
        @descr.mathjax()
        @scroll_visible(@document, t)

    scroll_visible: (list, entry) ->
        # if the selected entry is not visible, we have to make it visible
        relOffset = entry.position().top
        if relOffset > list.height()
            list.scrollTop(relOffset)
        else if relOffset < 0
            prev_height = 0
            entry.prevAll().each(() ->
                prev_height += $(this).outerHeight()
            )
            offset = relOffset + prev_height
            list.scrollTop(offset)

    _list_sort: (a, b) ->
        # ordering operator, such that some entries are in front
        ord = (el) -> switch el
            when "Tutorial" then -1
            when "Intro"    then -2
            else 0
        return ord(a) - ord(b) || a > b

    fill_list: (list, entries) ->
        list.empty()
        if entries?
            keys = _.keys(entries).sort(@_list_sort)
            for key in keys
                # <li class="list-group-item active"><span class="badge">3</span>...</li>
                if list == @document
                    list.append($("<li class='list-group-item' data='#{key}'>#{key}</li>"))
                else
                    subdocs = entries[key]
                    nb = _.keys(subdocs).length
                    list.append($("<li class='list-group-item' data='#{key}'><span class='badge'>#{nb}</span>#{key}</li>"))

            if keys.length == 1
                key = keys[0]
                entries2 = entries[key]
                if list == @lvl1
                    #@cat1 = key
                    #@fill_list(@lvl2, entries2)
                    @select_lvl1(@lvl1.find("[data=#{key}]"))
                else if list == @lvl2
                    #@cat2 = key
                    #@fill_list(@document, entries2)
                    @select_lvl2(@lvl2.find("[data=#{key}]"))

exports.show = () -> new Wizard()
