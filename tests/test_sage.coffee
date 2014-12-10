####################################################
#
# Test NodeJS TCP interface to a sage_server
#
# ASSUMPTION: there is a TCP sage server on localhost, port 6000
#         sage --python sage_server.py -p 6000 --address 127.0.0.1
#
####################################################
#
HOST = 'localhost'
PORT = 6000

sage    = require('sage')
message = require("message")

exports.test_2plus2 = (test) ->
    test.expect(10)

    pid = null
    conn = new sage.Connection
        host: HOST
        port: PORT
        recv: (type, mesg) ->
            test.equal(type, 'json')
            switch mesg.event
                when "session_description"
                    test.ok(mesg.pid?, "got back a pid")
                    pid = mesg.pid
                    conn.send_json(message.execute_code(code:"2+2", id:'xyz'))
                when "output"
                    test.equal(mesg.id, 'xyz', "got back valid message id of xyz")
                    test.equal(mesg.stdout, '4\n', "got stdout of '4'")
                    test.equal(mesg.stderr, undefined, "got no stderr output")
                    test.ok(mesg.done, "done is true -- for 2+2 computation")
                    sage.send_signal(host:HOST, port:PORT, pid:pid, signal:3)
                when "terminate_session"
                    test.ok(mesg.done, "done is true")
                    conn.close()
                    test.done()
        cb: ->
            test.ok(true)  # connected
            conn.send_json(message.start_session(limits:{walltime:10}))

