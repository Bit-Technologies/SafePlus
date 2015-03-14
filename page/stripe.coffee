###############################################################################
#
# SageMathCloud: A collaborative web-based interface to Sage, IPython, LaTeX and the Terminal.
#
#    Copyright (C) 2015, William Stein
#    SageMath, Inc.
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

################################################
# Stripe Billing code
################################################

async           = require('async')
misc            = require('misc')
{alert_message} = require('alerts')
defaults        = misc.defaults
required        = defaults.required
projects        = require('projects')

{salvus_client} = require('salvus_client')

stripe_ui = undefined
exports.stripe_user_interface = () ->
    if stripe_ui?
        return stripe_ui
    stripe_ui = new STRIPE($("#smc-billing-tab"))
    return stripe_ui

templates = $(".smc-stripe-templates")

stripe_date = (d) ->
    return new Date(d*1000).toLocaleDateString( 'lookup', { year: 'numeric', month: 'long', day: 'numeric' })

log = (x,y,z) -> console.log('stripe: ', x,y,z)


class STRIPE
    constructor: (elt) ->
        @element = templates.find(".smc-stripe-page").clone()
        elt.empty()
        elt.append(@element)
        @init()
        window.s = @

    init: () =>
        @elt_cards = @element.find(".smc-stripe-page-card")
        @element.find("a[href=#new-card]").click(@new_card)
        @element.find("a[href=#new-subscription]").click(@new_subscription)

    update_customer: (cb) =>
        salvus_client.stripe_get_customer
            cb : (err, resp) =>
                #log("stripe_get_customer #{err}, #{misc.to_json(resp)}")
                if err or not resp.stripe_publishable_key
                    $("#smc-billing-tab span").text("Billing is not yet available.")
                    $(".smc-nonfree").hide()
                    $(".smc-freeonly").show()
                    cb(true)
                else
                    $(".smc-nonfree").show()
                    $(".smc-freeonly").hide()
                    Stripe.setPublishableKey(resp.stripe_publishable_key)
                    @set_customer(resp.customer)
                    cb()

    update: (cb) =>
        $(".smc-billing-tab-refresh-spinner").show().addClass('fa-spin')
        #log("update")
        async.series([
            (cb) =>
                @update_customer (err) =>
                    if err
                        cb(err)
                    else
                        @render_cards_and_subscriptions()
                        cb()
            (cb) =>
                salvus_client.stripe_get_charges
                    cb: (err, charges) =>
                        if err
                            cb(err)
                        else
                            @set_charges(charges)
                            @render_charges()
                            cb()
        ], (err) =>
            $(".smc-billing-tab-refresh-spinner").removeClass('fa-spin')
            cb?(err)
        )

    set_customer: (customer) =>
        @customer = customer
        if not @customer?
            @customer =
                cards         : {data:[]}
                subscriptions : {data:[]}

    render_cards_and_subscriptions: () =>
        @render_cards()
        @render_subscriptions()
        if @customer.cards.data.length > 0
            @element.find("a[href=#new-subscription]").removeClass("disabled")
        else
            @element.find("a[href=#new-subscription]").addClass("disabled")

    render_one_card: (card) =>
        log('render_one_card', card)
        # card is a map with domain
        #    id, object, last4, brand, funding, exp_month, exp_year, fingerprint, country, name, address_line1, address_line2, address_city, address_state, address_zip, address_country, cvc_check, address_line1_check, address_zip_check, dynamic_last4, metadata, customer
        elt = templates.find(".smc-stripe-card").clone()
        if card?
            elt.attr('id', card.id)
            for k, v of card
                if v? and v != null
                    t = elt.find(".smc-stripe-card-#{k}")
                    if t.length > 0
                        t.text(v)
            x = elt.find(".smc-stripe-card-brand-#{card.brand}")
            if x.length > 0
                x.show()
            else
                elt.find(".smc-stripe-card-brand-Other").show()

        elt.smc_toggle_details
            show   : '.smc-stripe-card-show-details'
            hide   : '.smc-stripe-card-hide-details'
            target : '.smc-strip-card-details'

        elt.find("a[href=#delete-card]").click () =>
            @delete_card(card)
            return false

        elt.find("a[href=#set-as-default]").click () =>
            @set_card_as_default(card, elt.find("a[href=#set-as-default]"))
            return false

        if @customer.default_card == card.id
            elt.find("a[href=#set-as-default]").addClass("btn-primary").removeClass('btn-default').addClass('disabled')

        return elt

    set_card_as_default: (card, elt, cb) =>
        log("set_card_as_default")
        m = "<h4 style='font-weight:bold'><i class='fa-warning-sign'></i>  Change Default Payment Method</h4>  Are you sure you want to use your #{card.brand} card by default for subscription and invoice payments?<br><br>"
        bootbox.confirm m, (result) =>
            if result
                elt.icon_spin(start:true)
                salvus_client.stripe_set_default_card
                    card_id : card.id
                    cb      : (err) =>
                        if err
                            elt.icon_spin(false)
                            alert_message
                                type    : "error"
                                message : "Error trying to make your #{card.brand} card the default -- #{err}"
                            cb?(err)
                        else
                            @update (err) =>
                                elt.icon_spin(false)
                                alert_message
                                    type    : "info"
                                    message : "Your #{card.brand} card will now be used by default for subscription and invoice payments."
                                cb?(err)
            else
                cb?()

    delete_card: (card, cb) =>
        log("delete_card")
        m = "<h4 style='color:red;font-weight:bold'><i class='fa fa-trash-o'></i>  Delete Payment Method</h4>  Are you sure you want to remove this <b>#{card.brand}</b> payment method?<br><br>"
        bootbox.confirm m, (result) =>
            if result
                salvus_client.stripe_delete_card
                    card_id : card.id
                    cb      : (err) =>
                        if err
                            alert_message
                                type    : "error"
                                message : "Error trying to delete your #{card.brand} card -- #{err}"
                        else
                            alert_message
                                type    : "info"
                                message : "Your #{card.brand} card has been deleted."
                            @update()
                        cb?(err)
            else
                cb?()

    # this does not query the server -- it uses the last cached/known result.
    has_a_billing_method: () =>
        return @customer?.cards? and @customer.cards.data.length > 0

    render_cards: () =>
        log("render_cards")
        if not @customer?.cards?
            # nothing to do
            return
        cards = @customer.cards
        panel = @element.find(".smc-stripe-cards-panel").show()
        elt_cards = panel.find(".smc-stripe-page-cards")
        elt_cards.empty()
        for card in cards.data
            elt_cards.append(@render_one_card(card))

        if cards.data.length > 1
            panel.find("a[href=#set-as-default]").show()
        else
            panel.find("a[href=#set-as-default]").hide()

        if cards.has_more
            panel.find("a[href=#show-more]").show().click () =>
                @show_all_cards()
        else
            panel.find("a[href=#show-more]").hide()

    render_one_subscription: (subscription) =>
        log('render_one_subscription', subscription)
        ###
        #
        # subscription is a map with domain
        #
        #    id, plan, object, start, status, customer, cancel_at_period_end, current_period_start, current_period_end,
        #    ended_at, trial_start, trial_end, canceled_at, quantity, application_fee_percent, discount, tax_percent, metadata
        #
        # The plan is another map with domain:
        #
        #    interval, name, created, amount, currency, id, object, livemode, interval_count, trial_period_days,
        #    metadata, statement_descriptor
        #
        ###
        elt = templates.find(".smc-stripe-subscription").clone()
        elt.attr('id', subscription.id)

        #elt.find(".smc-stripe-subscription-quantity").text(subscription.quantity)

        titles = []
        if subscription.metadata.projects?
            salvus_client.get_project_titles
                project_ids : misc.from_json(subscription.metadata.projects)
                cb          : (err, v) =>
                    e = elt.find(".smc-stripe-subscription-project-titles")
                    f = (evt) ->
                        project_id = $(evt.target).data('id')
                        projects.open_project
                            project : project_id
                        return false
                    for project_id, title of v
                        a = $("<a style='margin-right:3em'>").text(misc.trunc(title,80)).data(id:project_id)
                        a.click(f)
                        e.append(a)
                        titles.push(title)
        desc = titles.join('; ')


        for k in ['start', 'current_period_start', 'current_period_end']
            v = subscription[k]
            if v
                elt.find(".smc-stripe-subscription-#{k}").text(stripe_date(v))

        plan = subscription.plan
        elt.find(".smc-stripe-subscription-plan-name").text(plan.name)

        elt.find("a[href=#cancel-subscription]").click () =>
            @cancel_subscription
                subscription_id : subscription.id
                elt             : elt.find("a[href=#cancel-subscription]")
                desc            : desc
            return false

        # TODO: make currency more sophisticated
        elt.find(".smc-stripe-subscription-plan-amount").text("$#{plan.amount/100}/month")  #TODO!

        elt.smc_toggle_details
            show   : '.smc-stripe-subscription-show-details'
            hide   : '.smc-stripe-subscription-hide-details'
            target : '.smc-strip-subscription-details'

        return elt

    render_subscriptions: () =>
        log("render_subscriptions")
        subscriptions = @customer.subscriptions
        panel = @element.find(".smc-stripe-subscriptions-panel")
        if subscriptions.data.length == 0 and @customer.cards.data.length == 0
            # no way to pay and no subscriptions yet -- don't show
            panel.hide()
            return
        else
            panel.show()
        elt_subscriptions = panel.find(".smc-stripe-page-subscriptions")
        elt_subscriptions.empty()
        for subscription in subscriptions.data
            elt_subscriptions.append(@render_one_subscription(subscription))

        if subscriptions.has_more
            panel.find("a[href=#show-more]").show().click () =>
                @show_all_subscriptions()
        else
            panel.find("a[href=#show-more]").hide()

    cancel_subscription: (opts) =>
        opts = defaults opts,
            subscription_id : required
            elt             : required
            desc            : 'Project upgrade'
            cb              : undefined
        log("cancel_subscription")
        m = "<h4 style='color:red;font-weight:bold'><i class='fa fa-times'></i>  Cancel Subscription</h4>  Are you sure you want to cancel your nonfree subscription for <em>'#{opts.desc}'</em>?<br><br>This project will move to a non-commercial-use only datacenter.<br><br>"
        bootbox.confirm m, (result) =>
            if result
                opts.elt.icon_spin(start:true)
                salvus_client.stripe_cancel_subscription
                    subscription_id : opts.subscription_id
                    cb              : (err) =>
                        opts.elt.icon_spin(false)
                        if err
                            alert_message
                                type    : "error"
                                message : "Error trying to cancel subscription for '#{opts.desc}' -- #{err}"
                        else
                            alert_message
                                type    : "info"
                                message : "Canceled project subscription for '#{opts.desc}' "
                            @update()
                        opts.cb?(err)
            else
                opts.cb?()


    set_charges: (charges) =>
        @charges = charges

    render_one_charge: (charge) =>
        log('render_one_charge', charge)
        elt = templates.find(".smc-stripe-charge").clone()
        elt.attr('id', charge.id)

        elt.find(".smc-stripe-charge-amount").text("$#{charge.amount/100}") # TODO
        if charge.description
            elt.find(".smc-stripe-charge-plan-name").text(charge.description)

        elt.find(".smc-stripe-charge-created").text(stripe_date(charge.created))

        elt.smc_toggle_details
            show   : '.smc-stripe-charge-show-details'
            hide   : '.smc-stripe-charge-hide-details'
            target : '.smc-stripe-charge-details'

        return elt

    render_charges: () =>
        log("render_charges")
        charges = @charges
        if not charges?
            return
        panel = @element.find(".smc-stripe-charges-panel")
        if charges.data.length == 0
            # no charges yet -- don't show
            panel.hide()
            return
        else
            panel.show()
        elt_charges = panel.find(".smc-stripe-page-charges")
        elt_charges.empty()
        for charge in charges.data
            elt_charges.prepend(@render_one_charge(charge))

        if charges.has_more
            panel.find("a[href=#show-more]").show().click () =>
                @show_all_charges()
        else
            panel.find("a[href=#show-more]").hide()

    new_card: (cb) =>   # cb?(true if created card; otherwise false)
        log("new_card")
        dialog = templates.find(".smc-stripe-new-card").clone()
        btn = dialog.find(".btn-submit")
        dialog.find(".smc-stripe-form-name").val(require('account').account_settings.fullname())
        dialog.find(".smc-stripe-credit-card-number").focus()
        submit = (do_it) =>
            if not do_it
                cb?(do_it)
                dialog.modal('hide')
                return
            form = dialog.find("form")
            btn.icon_spin(start:true).addClass('disabled')
            response = undefined
            async.series([
                (cb) =>
                    Stripe.card.createToken form, (status, _response) =>
                        if status != 200
                            cb(_response.error.message)
                        else
                            response = _response
                            cb()
                (cb) =>
                    salvus_client.stripe_create_card
                        token : response.id
                        cb    : cb
            ], (err) =>
                btn.icon_spin(false).removeClass('disabled')
                if err
                    dialog.find(".smc-stripe-card-error-row").show()
                    dialog.find(".smc-stripe-card-errors").text(err)
                else
                    @update()
                    dialog.modal('hide')
                    cb?(do_it)
            )
            return false

        dialog.find(".smc-stripe-credit-card-number").validateCreditCard (result) =>
            console.log("validate result=", result)
            elt = dialog.find(".smc-stripe-credit-card-number-group")
            elt.find("i").hide()
            if result.valid
                i = elt.find(".fa-cc-#{result.card_type.name}")
                if i.length > 0
                    i.show()
                else
                    elt.find(".fa-credit-card").show()
                elt.find(".fa-check").show()
                elt.find(".smc-stripe-credit-card-invalid").hide()
            else
                elt.find(".smc-stripe-credit-card-invalid").show()

        dialog.submit(submit)
        dialog.find("form").submit(submit)
        btn.click(submit)
        dialog.find(".btn-close").click(() => submit(false))
        dialog.modal()
        return false

    edit_card: (card) =>
        log("edit_card")

    new_subscription: () =>
        log("new_subscription")
        dialog         = templates.find(".smc-stripe-new-subscription").clone()
        btn            = dialog.find(".btn-submit")
        project_select = dialog.find(".smc-stripe-new-subscription-project")
        plan_select    = dialog.find(".smc-stripe-new-subscription-plan")
        coupon         = dialog.find(".smc-stripe-new-subscription-coupon")

        show_error = (err) ->
            dialog.find(".smc-stripe-subscription-error-row").show()
            dialog.find(".smc-stripe-subscription-errors").text(err)

        async.parallel([
            (cb) =>
                # todo -- exclude projects that are already upgraded.
                exclude = []
                projects.get_project_list
                    update         : false
                    select         : project_select
                    select_exclude : exclude
                    cb             : (err, x) =>
                        if err
                            cb("Unable to get projects: #{err}")
                        else
                            project_list = (a for a in x when not a.deleted)
                            if project_list.length == 0
                                cb("Please create a project first")
                            else
                                cb()
            (cb) =>
                salvus_client.stripe_get_plans
                    cb : (err, plans) =>
                        if err
                            cb("Unable to get available plans: #{err}")
                        else
                            for plan in plans.data
                                plan_select.append("<option value='#{plan.id}'>#{plan.name} ($#{plan.amount/100}/#{plan.interval})</option>")
                            cb()
        ], (err) =>
            if err
                alert_message(type:"error", message:err)
            else
                submit = () =>
                    btn.icon_spin(start:true).addClass('disabled')
                    coupon_code = coupon.val().trim()
                    if not coupon_code
                        coupon_code = undefined  # required by stripe api
                    salvus_client.stripe_create_subscription
                        plan     : plan_select.val()
                        coupon   : coupon_code
                        projects : [project_select.val()]
                        cb       : (err) =>
                            btn.icon_spin(false).removeClass('disabled')
                            if err
                                show_error(err)
                            else
                                @update()
                                dialog.modal('hide')

                dialog.submit(submit)
                dialog.find("form").submit(submit)
                btn.click(submit)
                dialog.modal()
        )

        return false

