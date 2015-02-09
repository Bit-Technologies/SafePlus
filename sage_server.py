#!/usr/bin/env python
"""
sage_server.py -- unencrypted forking TCP server.

Note: I wrote functionality so this can run as root, create accounts on the fly,
and serve sage as those accounts.  Doing this is horrendous from a security point of
view, and I'm definitely not doing this.  None of that functionality is actually
used in https://cloud.sagemath.com!

For debugging, this may help:

    killemall sage_server.py && sage --python sage_server.py -p 6000

"""

# NOTE: This file is GPL'd
# because it imports the Sage library.  This file is not directly
# imported by anything else in Salvus; the Python process it runs is
# used over a TCP connection.

#########################################################################################
#       Copyright (C) 2013 William Stein <wstein@gmail.com>                             #
#                                                                                       #
#  Distributed under the terms of the GNU General Public License (GPL), version 2+      #
#                                                                                       #
#                  http://www.gnu.org/licenses/                                         #
#########################################################################################

# Add the path that contains this file to the Python load path, so we
# can import other files from there.
import os, sys
PWD = os.path.split(os.path.realpath(__file__))[0]
sys.path.insert(0, PWD)

# used for clearing pylab figure
pylab = None

# Maximum number of distinct (non-once) output messages per cell; when this number is
# exceeded, an exception is raised; this reduces the chances of the user creating
# a huge unusable worksheet.
MAX_OUTPUT_MESSAGES = 256
# stdout, stderr, html, etc. that exceeds this many characters will be truncated to avoid
# killing the client.
MAX_STDOUT_SIZE = MAX_STDERR_SIZE = MAX_CODE_SIZE = MAX_HTML_SIZE = MAX_MD_SIZE = 100000
MAX_TEX_SIZE = 2000

# We import the notebook interact, which we will monkey patch below,
# first, since importing later causes trouble in sage>=5.6.
import sagenb.notebook.interact

# Standard imports.
import json, resource, shutil, signal, socket, struct, \
       tempfile, time, traceback, pwd

import sage_parsing, sage_salvus

uuid = sage_salvus.uuid

def unicode8(s):
    # I evidently don't understand Python unicode...  Do the following for now:
    # TODO: see http://stackoverflow.com/questions/21897664/why-does-unicodeu-passed-an-errors-parameter-raise-typeerror for how to fix.
    try:
        return unicode(s, 'utf8')
    except:
        try:
             return unicode(s)
        except:
             return s

LOGFILE = os.path.realpath(__file__)[:-3] + ".log"
PID = os.getpid()
def log(*args):
    try:
        debug_log = open(LOGFILE, 'a')
        mesg = "%s: %s\n"%(PID,' '.join([unicode8(x) for x in args]))
        debug_log.write(mesg)
        debug_log.flush()
    except:
        log("an error writing a log message (ignoring)")

# Determine the info object, if available.  There's no good reason
# it wouldn't be available, unless a user explicitly deleted it, but
# we may as well try to be robust to this, especially if somebody
# were to try to use this server outside of cloud.sagemath.com.
_info_path = os.path.join(os.environ['SAGEMATHCLOUD'], 'info.json')
if os.path.exists(_info_path):
    INFO = json.loads(open(_info_path).read())
else:
    INFO = {}
if 'base_url' not in INFO:
    INFO['base_url'] = ''


# Configure logging
#logging.basicConfig()
#log = logging.getLogger('sage_server')
#log.setLevel(logging.INFO)

# A CoffeeScript version of this function is in misc_node.coffee.
import hashlib
def uuidsha1(data):
    sha1sum = hashlib.sha1()
    sha1sum.update(data)
    s = sha1sum.hexdigest()
    t = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    r = list(t)
    j = 0
    for i in range(len(t)):
        if t[i] == 'x':
            r[i] = s[j]; j += 1
        elif t[i] == 'y':
            # take 8 + low order 3 bits of hex number.
            r[i] = hex( (int(s[j],16)&0x3) |0x8)[-1]; j += 1
    return ''.join(r)

# A tcp connection with support for sending various types of messages, especially JSON.
class ConnectionJSON(object):
    def __init__(self, conn):
        assert not isinstance(conn, ConnectionJSON)  # avoid common mistake -- conn is supposed to be from socket.socket...
        self._conn = conn

    def close(self):
        self._conn.close()

    def _send(self, s):
        length_header = struct.pack(">L", len(s))
        self._conn.send(length_header + s)

    def send_json(self, m):
        m = json.dumps(m)
        log(u"sending message '", truncate_text(m, 256), u"'")
        self._send('j' + m)

    def send_blob(self, blob):
        s = uuidsha1(blob)
        self._send('b' + s + blob)
        return s

    def send_file(self, filename):
        log("sending file '%s'"%filename)
        f = open(filename, 'rb')
        data = f.read()
        f.close()
        return self.send_blob(data)

    def _recv(self, n):
        #print "_recv(%s)"%n
        for i in range(20): # see http://stackoverflow.com/questions/3016369/catching-blocking-sigint-during-system-call
            try:
                #print "blocking recv (i = %s), pid=%s"%(i, os.getpid())
                r = self._conn.recv(n)
                #log("n=%s; received: '%s' of len %s"%(n,r, len(r)))
                return r
            except socket.error as (errno, msg):
                #print "socket.error, msg=%s"%msg
                if errno != 4:
                    raise
        raise EOFError

    def recv(self):
        n = self._recv(4)
        if len(n) < 4:
            raise EOFError
        n = struct.unpack('>L', n)[0]   # big endian 32 bits
        s = self._recv(n)
        while len(s) < n:
            t = self._recv(n - len(s))
            if len(t) == 0:
                raise EOFError
            s += t

        if s[0] == 'j':
            try:
                return 'json', json.loads(s[1:])
            except Exception, msg:
                log("Unable to parse JSON '%s'"%s[1:])
                raise

        elif s[0] == 'b':
            return 'blob', s[1:]
        raise ValueError("unknown message type '%s'"%s[0])

def truncate_text(s, max_size):
    if len(s) > max_size:
        return s[:max_size] + "[...]"
    else:
        return s


class Message(object):
    def _new(self, event, props={}):
        m = {'event':event}
        for key, val in props.iteritems():
            if key != 'self':
                m[key] = val
        return m

    def start_session(self):
        return self._new('start_session')

    def session_description(self, pid):
        return self._new('session_description', {'pid':pid})

    def send_signal(self, pid, signal=signal.SIGINT):
        return self._new('send_signal', locals())

    def terminate_session(self, done=True):
        return self._new('terminate_session', locals())

    def execute_code(self, id, code, preparse=True):
        return self._new('execute_code', locals())

    def execute_javascript(self, code, obj=None, coffeescript=False):
        return self._new('execute_javascript', locals())

    def output(self, id,
               stdout       = None,
               stderr       = None,
               code         = None,
               html         = None,
               javascript   = None,
               coffeescript = None,
               interact     = None,
               md           = None,
               tex          = None,
               d3           = None,
               file         = None,
               obj          = None,
               done         = None,
               once         = None,
               hide         = None,
               show         = None,
               auto         = None,
               events       = None,
               clear        = None):
        m = self._new('output')
        m['id'] = id
        t = truncate_text
        import sage_server  # we do this so that the user can customize the MAX's below.
        if code is not None:
            code['source'] = t(code['source'], sage_server.MAX_CODE_SIZE)
            m['code'] = code
        if stderr is not None and len(stderr) > 0:
            m['stderr'] = t(stderr, sage_server.MAX_STDERR_SIZE)
        if stdout is not None and len(stdout) > 0:
            m['stdout'] = t(stdout, sage_server.MAX_STDOUT_SIZE)
        if html is not None  and len(html) > 0:
            m['html'] = t(html, sage_server.MAX_HTML_SIZE)
        if md is not None  and len(md) > 0:
            m['md'] = t(md, sage_server.MAX_MD_SIZE)
        if tex is not None and len(tex)>0:
            tex['tex'] = t(tex['tex'], sage_server.MAX_TEX_SIZE)
            m['tex'] = tex
        if javascript is not None: m['javascript'] = javascript
        if coffeescript is not None: m['coffeescript'] = coffeescript
        if interact is not None: m['interact'] = interact
        if d3 is not None: m['d3'] = d3
        if obj is not None: m['obj'] = json.dumps(obj)
        if file is not None: m['file'] = file    # = {'filename':..., 'uuid':...}
        if done is not None: m['done'] = done
        if once is not None: m['once'] = once
        if hide is not None: m['hide'] = hide
        if show is not None: m['show'] = show
        if auto is not None: m['auto'] = auto
        if events is not None: m['events'] = events
        if clear is not None: m['clear'] = clear
        return m

    def introspect_completions(self, id, completions, target):
        m = self._new('introspect_completions', locals())
        m['id'] = id
        return m

    def introspect_docstring(self, id, docstring, target):
        m = self._new('introspect_docstring', locals())
        m['id'] = id
        return m

    def introspect_source_code(self, id, source_code, target):
        m = self._new('introspect_source_code', locals())
        m['id'] = id
        return m

message = Message()

whoami = os.environ['USER']

def client1(port, hostname):
    conn = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    conn.connect((hostname, int(port)))
    conn = ConnectionJSON(conn)

    conn.send_json(message.start_session())
    typ, mesg = conn.recv()
    pid = mesg['pid']
    print "PID = %s"%pid

    id = 0
    while True:
        try:
            code = sage_parsing.get_input('sage [%s]: '%id)
            if code is None:  # EOF
                break
            conn.send_json(message.execute_code(code=code, id=id))
            while True:
                typ, mesg = conn.recv()
                if mesg['event'] == 'terminate_session':
                    return
                elif mesg['event'] == 'output':
                    if 'stdout' in mesg:
                        sys.stdout.write(mesg['stdout']); sys.stdout.flush()
                    if 'stderr' in mesg:
                        print '!  ' + '\n!  '.join(mesg['stderr'].splitlines())
                    if 'done' in mesg and mesg['id'] >= id:
                        break
            id += 1

        except KeyboardInterrupt:
            print "Sending interrupt signal"
            conn2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            conn2.connect((hostname, int(port)))
            conn2 = ConnectionJSON(conn2)
            conn2.send_json(message.send_signal(pid))
            del conn2
            id += 1

    conn.send_json(message.terminate_session())
    print "\nExiting Sage client."

class BufferedOutputStream(object):
    def __init__(self, f, flush_size=4096, flush_interval=.1):
        self._f = f
        self._buf = ''
        self._flush_size = flush_size
        self._flush_interval = flush_interval
        self.reset()

    def reset(self):
        self._last_flush_time = time.time()

    def fileno(self):
        return 0

    def write(self, output):
        self._buf += output
        #self.flush()
        t = time.time()
        if ((len(self._buf) >= self._flush_size) or
                  (t - self._last_flush_time >= self._flush_interval)):
            self.flush()
            self._last_flush_time = t

    def flush(self, done=False):
        if not self._buf and not done:
            # no point in sending an empty message
            return
        self._f(self._buf, done=done)
        self._buf = ''


# This will *have* to be re-done using Cython for speed.
class Namespace(dict):
    def __init__(self, x):
        self._on_change = {}
        self._on_del = {}
        dict.__init__(self, x)

    def on(self, event, x, f):
        if event == 'change':
            if x not in self._on_change:
                self._on_change[x] = []
            self._on_change[x].append(f)
        elif event == 'del':
            if x not in self._on_del:
                self._on_del[x] = []
            self._on_del[x].append(f)

    def remove(self, event, x, f):
        if event == 'change' and self._on_change.has_key(x):
            v = self._on_change[x]
            i = v.find(f)
            if i != -1:
                del v[i]
            if len(v) == 0:
                del self._on_change[x]
        elif event == 'del' and self._on_del.has_key(x):
            v = self._on_del[x]
            i = v.find(f)
            if i != -1:
                del v[i]
            if len(v) == 0:
                del self._on_del[x]

    def __setitem__(self, x, y):
        dict.__setitem__(self, x, y)
        try:
            if self._on_change.has_key(x):
                for f in self._on_change[x]:
                    f(y)
            if self._on_change.has_key(None):
                for f in self._on_change[None]:
                    f(x, y)
        except Exception, mesg:
            print mesg

    def __delitem__(self, x):
        try:
            if self._on_del.has_key(x):
                for f in self._on_del[x]:
                    f()
            if self._on_del.has_key(None):
                for f in self._on_del[None]:
                    f(x)
        except Exception, mesg:
            print mesg
        dict.__delitem__(self, x)

    def set(self, x, y, do_not_trigger=None):
        dict.__setitem__(self, x, y)
        if self._on_change.has_key(x):
            if do_not_trigger is None:
                do_not_trigger = []
            for f in self._on_change[x]:
                if f not in do_not_trigger:
                    f(y)
        if self._on_change.has_key(None):
            for f in self._on_change[None]:
                f(x,y)

class TemporaryURL:
    def __init__(self, url, ttl):
        self.url = url
        self.ttl = ttl
    def __repr__(self):
        return repr(self.url)
    def __str__(self):
        return self.url

namespace = Namespace({})

class Salvus(object):
    """
    Cell execution state object and wrapper for access to special SageMathCloud functionality.

    An instance of this object is created each time you execute a cell.  It has various methods
    for sending different types of output messages, links to files, etc.

    OUTPUT LIMITATIONS -- There is an absolute limit on the number of messages output for a given
    cell, and also the size of the output message for each cell.  You can access or change
    those limits dynamically in a worksheet as follows by viewing or changing any of the
    following variables::

        import sage_server
        sage_server.MAX_STDOUT_SIZE   # max length of each stdout output message
        sage_server.MAX_STDERR_SIZE   # max length of each stderr output message
        sage_server.MAX_MD_SIZE       # max length of each md (markdown) output message
        sage_server.MAX_HTML_SIZE     # max length of each html output message
        sage_server.MAX_TEX_SIZE      # max length of tex output message
        sage_server.MAX_OUTPUT_MESSAGES   # max number of messages output for a cell.
    """
    Namespace = Namespace
    _prefix       = ''
    _postfix      = ''
    _default_mode = 'sage'

    def _flush_stdio(self):
        """
        Flush the standard output streams.  This should be called before sending any message
        that produces output.
        """
        sys.stdout.flush()
        sys.stderr.flush()

    def __repr__(self):
        return ''

    def __init__(self, conn, id, data=None, cell_id=None, message_queue=None):
        self._conn = conn
        self._num_output_messages = 0
        self._id   = id
        self._done = True    # done=self._done when last execute message is sent; e.g., set self._done = False to not close cell on code term.
        self.data = data
        self.cell_id = cell_id
        self.namespace = namespace
        self.message_queue = message_queue
        self.code_decorators = [] # gets reset if there are code decorators
        namespace['salvus'] = self   # beware of circular ref?
        # Monkey patch in our "require" command.
        namespace['require'] = self.require
        # Make the salvus object itself available when doing "from sage.all import *".
        import sage.all
        sage.all.salvus = self

    def _send_output(self, *args, **kwds):
        mesg = message.output(*args, **kwds)
        if not mesg.get('once',False):
            self._num_output_messages += 1
        import sage_server
        if self._num_output_messages > sage_server.MAX_OUTPUT_MESSAGES:
            if self._num_output_messages == sage_server.MAX_OUTPUT_MESSAGES+1:
                err = "\nToo many output messages (at most %s per cell): attempting to terminate..."%sage_server.MAX_OUTPUT_MESSAGES
                self._conn.send_json(message.output(stderr=err, id=self._id, once=False))
            if mesg.get('done',False):
                self._conn.send_json(message.output(done=True, id=self._id))
            raise KeyboardInterrupt

        self._conn.send_json(mesg)

    def obj(self, obj, done=False):
        self._send_output(obj=obj, id=self._id, done=done)
        return self

    def link(self, filename, label=None, foreground=True, cls=''):
        """
        Output a clickable link to a file somewhere in this project.  The filename
        path must be relative to the current working directory of the Python process.

        The simplest way to use this is

             salvus.link("../name/of/file")    # any relative path to any file

        This creates a link, which when clicked on, opens that file in the foreground.

        If the filename is the name of a directory, clicking will instead
        open the file browser on that directory:

             salvus.link("../name/of/directory")    # clicking on the resulting link opens a directory

        If you would like a button instead of a link, pass cls='btn'.  You can use any of
        the standard Bootstrap button classes, e.g., btn-small, btn-large, btn-success, etc.

        If you would like to change the text in the link (or button) to something
        besides the default (filename), just pass arbitrary HTML to the label= option.

        INPUT:

        - filename -- a relative path to a file or directory
        - label -- (default: the filename) html label for the link
        - foreground -- (default: True); if True, opens link in the foreground
        - cls -- (default: '') optional CSS classes, such as 'btn'.

        EXAMPLES:

        Use as a line decorator::

            %salvus.link name/of/file.foo

        Make a button::

            salvus.link("foo/bar/", label="The Bar Directory", cls='btn')

        Make two big blue buttons with plots in them::

            plot(sin, 0, 20).save('sin.png')
            plot(cos, 0, 20).save('cos.png')
            for img in ['sin.png', 'cos.png']:
                salvus.link(img, label="<img width='150px' src='%s'>"%salvus.file(img, show=False), cls='btn btn-large btn-primary')



        """
        path = os.path.abspath(filename)[len(os.environ['HOME'])+1:]
        if label is None:
            label = filename
        id = uuid()
        self.html("<a class='%s' style='cursor:pointer'; id='%s'></a>"%(cls, id))

        s = "$('#%s').html(obj.label).click(function() {%s; return false;});"%(id, self._action(path, foreground))
        self.javascript(s, obj={'label':label, 'path':path, 'foreground':foreground}, once=False)

    def _action(self, path, foreground):
        if os.path.isdir(path):
            action = "worksheet.project_page.chdir(obj.path);"
            if foreground:
                action += "worksheet.project_page.display_tab('project-file-listing');"
        else:
            action = "worksheet.project_page.open_file({'path':obj.path, 'foreground': obj.foreground});"
        return action

    def open_tab(self, filename, foreground=True):
        """
        Open a new file (or directory) document in another tab.
        See the documentation for salvus.link.
        """
        path = os.path.abspath(filename)[len(os.environ['HOME'])+1:]
        self.javascript(self._action(path, foreground),
                         obj = {'path':path, 'foreground':foreground}, once=True)

    def close_tab(self, filename):
        """
        Open an open file tab.  The filename is relative to the current working directory.
        """
        self.javascript("worksheet.editor.close(obj)", obj = filename, once=True)

    def threed(self,
               g,                   # sage Graphic3d object.
               width        = None,
               height       = None,
               frame        = True, # True/False or {'color':'black', 'thickness':.4, 'labels':True, 'fontsize':14, 'draw':True,
                                    #                'xmin':?, 'xmax':?, 'ymin':?, 'ymax':?, 'zmin':?, 'zmax':?}
               background   = None,
               foreground   = None,
               spin         = False,
               aspect_ratio = None,
               frame_aspect_ratio = None,  # synonym for aspect_ratio

               done         = False,
               renderer     = None,   # None, 'webgl', or 'canvas'
              ):

        from graphics import graphics3d_to_jsonable, json_float as f

        # process options, combining ones set explicitly above with ones inherited from 3d scene
        opts = { 'width':width, 'height':height,
                 'background':background, 'foreground':foreground,
                 'spin':spin, 'aspect_ratio':aspect_ratio,
                  'renderer':renderer}

        extra_kwds = {} if g._extra_kwds is None else g._extra_kwds

        # clean up and normalize aspect_ratio option
        if aspect_ratio is None:
            if frame_aspect_ratio is not None:
                aspect_ratio = frame_aspect_ratio
            elif 'frame_aspect_ratio' in extra_kwds:
                aspect_ratio = extra_kwds['frame_aspect_ratio']
            elif 'aspect_ratio' in extra_kwds:
                aspect_ratio = extra_kwds['aspect_ratio']
        if aspect_ratio is not None:
            if aspect_ratio == 1 or aspect_ratio == "automatic":
                aspect_ratio = None
            elif not (isinstance(aspect_ratio, (list, tuple)) and len(aspect_ratio) == 3):
                raise TypeError("aspect_ratio must be None, 1 or a 3-tuple, but it is '%s'"%(aspect_ratio,))
            else:
                aspect_ratio = [f(x) for x in aspect_ratio]

        opts['aspect_ratio'] = aspect_ratio

        for k in ['spin', 'height', 'width', 'background', 'foreground', 'renderer']:
            if k in extra_kwds and not opts.get(k,None):
                opts[k] = extra_kwds[k]

        if not isinstance(opts['spin'], bool):
            opts['spin'] = f(opts['spin'])
        opts['width']  = f(opts['width'])
        opts['height'] = f(opts['height'])

        # determine the frame
        b = g.bounding_box()
        xmin, xmax, ymin, ymax, zmin, zmax = b[0][0], b[1][0], b[0][1], b[1][1], b[0][2], b[1][2]
        fr = opts['frame'] = {'xmin':f(xmin), 'xmax':f(xmax),
                              'ymin':f(ymin), 'ymax':f(ymax),
                              'zmin':f(zmin), 'zmax':f(zmax)}

        if isinstance(frame, dict):
            for k in fr.keys():
                if k in frame:
                    fr[k] = f(frame[k])
            fr['draw'] = frame.get('draw', True)
            fr['color'] = frame.get('color', None)
            fr['thickness'] = f(frame.get('thickness', None))
            fr['labels'] = frame.get('labels', None)
            if 'fontsize' in frame:
                fr['fontsize'] = int(frame['fontsize'])
        elif isinstance(frame, bool):
            fr['draw'] = frame

        # convert the Sage graphics object to a JSON object that can be rendered
        scene = {'opts' : opts,
                 'obj'  : graphics3d_to_jsonable(g)}

        # Store that object in the database, rather than sending it directly as an output message.
        # We do this since obj can easily be quite large/complicated, and managing it as part of the
        # document is too slow and doesn't scale.
        blob = json.dumps(scene, separators=(',', ':'))
        uuid = self._conn.send_blob(blob)

        # flush output (so any text appears before 3d graphics, in case they are interleaved)
        self._flush_stdio()

        # send message pointing to the 3d 'file', which will get downloaded from database
        self._send_output(id=self._id, file={'filename':unicode8("%s.sage3d"%uuid), 'uuid':uuid}, done=done)


    def d3_graph(self, g, **kwds):
        from graphics import graph_to_d3_jsonable
        self._send_output(id=self._id, d3={"viewer":"graph", "data":graph_to_d3_jsonable(g, **kwds)})

    def file(self, filename, show=True, done=False, download=False, once=False, events=None, raw=False):
        """
        Display or provide a link to the given file.  Raises a RuntimeError if this
        is not possible, e.g, if the file is too large.

        If show=True (the default), the browser will show the file,
        or provide a clickable link to it if there is no way to show it.

        If show=False, this function returns an object T such that
        T.url (or str(t)) is a string of the form "/blobs/filename?uuid=the_uuid"
        that can be used to access the file even if the file is immediately
        deleted after calling this function (the file is stored in a database).
        Also, T.ttl is the time to live (in seconds) of the object.  A ttl of
        0 means the object is permanently available.

        raw=False (the default):
            If you use the URL
                   /blobs/filename?uuid=the_uuid&download
            then the server will include a header that tells the browser to
            download the file to disk instead of displaying it.  Only relatively
            small files can be made available this way.  However, they remain
            available (for a day) even *after* the file is deleted.
            NOTE: It is safe to delete the file immediately after this
            function (salvus.file) returns.

        raw=True:
            Instead, the URL is to the raw file, which is served directly
            from the project:
                   /project-id/raw/path/to/filename
            This will only work if the file is not deleted; however, arbitrarily
            large files can be streamed this way.

        This function creates an output message {file:...}; if the user saves
        a worksheet containing this message, then any referenced blobs are made
        permanent in the database.

        The uuid is based on the Sha-1 hash of the file content (it is computed using the
        function sage_server.uuidsha1).  Any two files with the same content have the
        same Sha1 hash.
        """
        filename = unicode8(filename)
        if raw:
            info = self.project_info()
            path = os.path.abspath(filename)
            home = os.environ[u'HOME'] + u'/'
            if path.startswith(home):
                path = path[len(home):]
            else:
                raise ValueError(u"can only send raw files in your home directory")
            url  = os.path.join(u'/',info['base_url'].strip('/'), info['project_id'], u'raw', path.lstrip('/'))
            if show:
                self._flush_stdio()
                self._send_output(id=self._id, once=once, file={'filename':filename, 'url':url, 'show':show}, events=events, done=done)
                return
            else:
                return TemporaryURL(url=url, ttl=0)

        file_uuid = self._conn.send_file(filename)

        mesg = None
        while mesg is None:
            self.message_queue.recv()
            for i, (typ, m) in enumerate(self.message_queue.queue):
                if typ == 'json' and m.get('event') == 'save_blob' and m.get('sha1') == file_uuid:
                    mesg = m
                    del self.message_queue[i]
                    break

        if 'error' in mesg:
            raise RuntimeError("error saving blob -- %s"%mesg['error'])

        self._flush_stdio()
        self._send_output(id=self._id, once=once, file={'filename':filename, 'uuid':file_uuid, 'show':show}, events=events, done=done)
        if not show:
            info = self.project_info()
            url = u"%s/blobs/%s?uuid=%s"%(info['base_url'], filename, file_uuid)
            if download:
                url += u'?download'
            return TemporaryURL(url=url, ttl=mesg.get('ttl',0))

    def default_mode(self, mode=None):
        """
        Set the default mode for cell evaluation.  This is equivalent
        to putting %mode at the top of any cell that does not start
        with %.   Use salvus.default_mode() to return the current mode.
        Use salvus.default_mode("") to have no default mode.

        This is implemented using salvus.cell_prefix.
        """
        if mode is None:
            return Salvus._default_mode
        Salvus._default_mode = mode
        if mode == "sage":
            self.cell_prefix("")
        else:
            self.cell_prefix("%" + mode)

    def cell_prefix(self, prefix=None):
        """
        Make it so that the given prefix code is textually
        prepending to the input before evaluating any cell, unless
        the first character of the cell is a %.

        To append code at the end, use cell_postfix.

        INPUT:

        - ``prefix`` -- None (to return prefix) or a string ("" to disable)

        EXAMPLES:

        Make it so every cell is timed:

            salvus.cell_prefix('%time')

        Make it so cells are typeset using latex, and latex comments are allowed even
        as the first line.

            salvus.cell_prefix('%latex')

            %sage salvus.cell_prefix('')

        Evaluate each cell using GP (Pari) and display the time it took:

            salvus.cell_prefix('%time\n%gp')

            %sage salvus.cell_prefix('')   # back to normal
        """
        if prefix is None:
            return Salvus._prefix
        else:
            Salvus._prefix = prefix

    def cell_postfix(self, postfix=None):
        """
        Make it so that the given code is textually
        appended to the input before evaluating a cell.
        To prepend code at the beginning, use cell_prefix.

        INPUT:

        - ``postfix`` -- None (to return postfix) or a string ("" to disable)

        EXAMPLES:

        Print memory usage after evaluating each cell:

            salvus.cell_postfix('print "%s MB used"%int(get_memory_usage())')

        Return to normal

            salvus.set_cell_postfix('')

        """
        if postfix is None:
            return Salvus._postfix
        else:
            Salvus._postfix = postfix

    def execute(self, code, namespace=None, preparse=True, locals=None):
        if namespace is None:
            namespace = self.namespace

        # clear pylab figure (takes a few microseconds)
        if pylab is not None:
            pylab.clf()

        #code   = sage_parsing.strip_leading_prompts(code)  # broken -- wrong on "def foo(x):\n   print x"
        blocks = sage_parsing.divide_into_blocks(code)

        for start, stop, block in blocks:
            if preparse:
                block = sage_parsing.preparse_code(block)
            sys.stdout.reset(); sys.stderr.reset()
            try:
                b = block.rstrip()
                if b.endswith('??'):
                    p = sage_parsing.introspect(block,
                                   namespace=namespace, preparse=False)
                    self.code(source = p['result'], mode = "python")
                elif b.endswith('?'):
                    p = sage_parsing.introspect(block, namespace=namespace, preparse=False)
                    self.code(source = p['result'], mode = "text/x-rst")
                else:
                    exec compile(block+'\n', '', 'single') in namespace, locals
                sys.stdout.flush()
                sys.stderr.flush()
            except:
                sys.stdout.flush()
                sys.stderr.write('Error in lines %s-%s\n'%(start+1, stop+1))
                traceback.print_exc()
                sys.stderr.flush()
                break

    def execute_with_code_decorators(self, code_decorators, code, preparse=True, namespace=None, locals=None):
        """
        salvus.execute_with_code_decorators is used when evaluating
        code blocks that are set to any non-default code_decorator.
        """
        import sage  # used below as a code decorator
        if isinstance(code_decorators, (str, unicode)):
            code_decorators = [code_decorators]

        if preparse:
            code_decorators = map(sage_parsing.preparse_code, code_decorators)

        code_decorators = [eval(code_decorator, self.namespace) for code_decorator in code_decorators]

        # The code itself may want to know exactly what code decorators are in effect.
        # For example, r.eval can do extra things when being used as a decorator.
        self.code_decorators = code_decorators

        for i, code_decorator in enumerate(code_decorators):
            # eval is for backward compatibility
            if not hasattr(code_decorator, 'eval') and hasattr(code_decorator, 'before'):
                code_decorators[i] = code_decorator.before(code)

        for code_decorator in reversed(code_decorators):
            if hasattr(code_decorator, 'eval'):   # eval is for backward compatibility
                print code_decorator.eval(code, locals=self.namespace),
                code = ''
            elif code_decorator is sage:
                # special case -- the sage module (i.e., %sage) should do nothing.
                pass
            else:
                code = code_decorator(code)
            if code is None:
                code = ''

        if code != '' and isinstance(code, (str, unicode)):
            self.execute(code, preparse=preparse, namespace=namespace, locals=locals)

        for code_decorator in code_decorators:
            if not hasattr(code_decorator, 'eval') and hasattr(code_decorator, 'after'):
                code_decorator.after(code)

    def html(self, html, done=False, once=None):
        """
        Display html in the output stream.

        EXAMPLE:

            salvus.html("<b>Hi</b>")
        """
        self._flush_stdio()
        self._send_output(html=unicode8(html), id=self._id, done=done, once=once)

    def md(self, md, done=False, once=None):
        """
        Display markdown in the output stream.

        EXAMPLE:

            salvus.md("**Hi**")
        """
        self._flush_stdio()
        self._send_output(md=unicode8(md), id=self._id, done=done, once=once)

    def pdf(self, filename, **kwds):
        sage_salvus.show_pdf(filename, **kwds)

    def tex(self, obj, display=False, done=False, once=None, **kwds):
        """
        Display obj nicely using TeX rendering.

        INPUT:

        - obj -- latex string or object that is automatically be converted to TeX
        - display -- (default: False); if True, typeset as display math (so centered, etc.)
        """
        self._flush_stdio()
        tex = obj if isinstance(obj, str) else self.namespace['latex'](obj, **kwds)
        self._send_output(tex={'tex':tex, 'display':display}, id=self._id, done=done, once=once)
        return self

    def start_executing(self):
        self._send_output(done=False, id=self._id)

    def clear(self, done=False):
        """
        Clear the output of the current cell.
        """
        self._send_output(clear=True, id=self._id, done=done)

    def stdout(self, output, done=False, once=None):
        """
        Send the string output (or unicode8(output) if output is not a
        string) to the standard output stream of the compute cell.

        INPUT:

        - output -- string or object

        """
        stdout = output if isinstance(output, (str, unicode)) else unicode8(output)
        self._send_output(stdout=stdout, done=done, id=self._id, once=once)
        return self

    def stderr(self, output, done=False, once=None):
        """
        Send the string output (or unicode8(output) if output is not a
        string) to the standard error stream of the compute cell.

        INPUT:

        - output -- string or object

        """
        stderr = output if isinstance(output, (str, unicode)) else unicode8(output)
        self._send_output(stderr=stderr, done=done, id=self._id, once=once)
        return self

    def code(self, source,            # actual source code
                   mode     = None,   # the syntax highlight codemirror mode
                   filename = None,   # path of file it is contained in (if applicable)
                   lineno   = -1,   # line number where source starts (0-based)
                   done=False, once=None):
        """
        Send a code message, which is to be rendered as code by the client, with
        appropriate syntax highlighting, maybe a link to open the source file, etc.
        """
        source = source if isinstance(source, (str, unicode)) else unicode8(source)
        code = {'source'   : source,
                'filename' : filename,
                'lineno'   : int(lineno),
                'mode'     : mode}
        self._send_output(code=code, done=done, id=self._id, once=once)
        return self

    def _execute_interact(self, id, vals):
        if id not in sage_salvus.interacts:
            print "(Evaluate this cell to use this interact.)"
            #raise RuntimeError, "Error: No interact with id %s"%id
        else:
            sage_salvus.interacts[id](vals)

    def interact(self, f, done=False, once=None, **kwds):
        I = sage_salvus.InteractCell(f, **kwds)
        self._flush_stdio()
        self._send_output(interact = I.jsonable(), id=self._id, done=done, once=once)
        return sage_salvus.InteractFunction(I)

    def javascript(self, code, once=False, coffeescript=False, done=False, obj=None):
        """
        Execute the given Javascript code as part of the output
        stream.  This same code will be executed (at exactly this
        point in the output stream) every time the worksheet is
        rendered.

        See the docs for the top-level javascript function for more details.

        INPUT:

        - code -- a string
        - once -- boolean (default: FAlse); if True the Javascript is
          only executed once, not every time the cell is loaded. This
          is what you would use if you call salvus.stdout, etc.  Use
          once=False, e.g., if you are using javascript to make a DOM
          element draggable (say).  WARNING: If once=True, then the
          javascript is likely to get executed before other output to
          a given cell is even rendered.
        - coffeescript -- boolean (default: False); if True, the input
          code is first converted from CoffeeScript to Javascript.

        At least the following Javascript objects are defined in the
        scope in which the code is evaluated::

        - cell -- jQuery wrapper around the current compute cell
        - salvus.stdout, salvus.stderr, salvus.html, salvus.tex -- all
          allow you to write additional output to the cell
        - worksheet - jQuery wrapper around the current worksheet DOM object
        - obj -- the optional obj argument, which is passed via JSON serialization
        """
        if obj is None:
            obj = {}
        self._send_output(javascript={'code':code, 'coffeescript':coffeescript}, id=self._id, done=done, obj=obj, once=once)

    def coffeescript(self, *args, **kwds):
        """
        This is the same as salvus.javascript, but with coffeescript=True.

        See the docs for the top-level javascript function for more details.
        """
        kwds['coffeescript'] = True
        self.javascript(*args, **kwds)

    def _check_component(self, component):
        if component not in ['input', 'output']:
            raise ValueError("component must be 'input' or 'output'")

    def hide(self, component):
        """
        Hide the given component ('input' or 'output') of the cell.
        """
        self._check_component(component)
        self._send_output(self._id, hide=component)

    def show(self, component):
        """
        Show the given component ('input' or 'output') of the cell.
        """
        self._check_component(component)
        self._send_output(self._id, show=component)

    def auto(self, state=True):
        """
        Set whether or not the current cells is automatically executed when
        the Sage process restarts.
        """
        self._send_output(self._id, auto=state)

    def notify(self, **kwds):
        """
        Display a graphical notification using the pnotify Javascript library.

        INPUTS:

        - `title: false` - The notice's title.
        - `title_escape: false` - Whether to escape the content of the title. (Not allow HTML.)
        - `text: false` - The notice's text.
        - `text_escape: false` - Whether to escape the content of the text. (Not allow HTML.)
        - `styling: "bootstrap"` - What styling classes to use. (Can be either jqueryui or bootstrap.)
        - `addclass: ""` - Additional classes to be added to the notice. (For custom styling.)
        - `cornerclass: ""` - Class to be added to the notice for corner styling.
        - `nonblock: false` - Create a non-blocking notice. It lets the user click elements underneath it.
        - `nonblock_opacity: .2` - The opacity of the notice (if it's non-blocking) when the mouse is over it.
        - `history: true` - Display a pull down menu to redisplay previous notices, and place the notice in the history.
        - `auto_display: true` - Display the notice when it is created. Turn this off to add notifications to the history without displaying them.
        - `width: "300px"` - Width of the notice.
        - `min_height: "16px"` - Minimum height of the notice. It will expand to fit content.
        - `type: "notice"` - Type of the notice. "notice", "info", "success", or "error".
        - `icon: true` - Set icon to true to use the default icon for the selected style/type, false for no icon, or a string for your own icon class.
        - `animation: "fade"` - The animation to use when displaying and hiding the notice. "none", "show", "fade", and "slide" are built in to jQuery. Others require jQuery UI. Use an object with effect_in and effect_out to use different effects.
        - `animate_speed: "slow"` - Speed at which the notice animates in and out. "slow", "def" or "normal", "fast" or number of milliseconds.
        - `opacity: 1` - Opacity of the notice.
        - `shadow: true` - Display a drop shadow.
        - `closer: true` - Provide a button for the user to manually close the notice.
        - `closer_hover: true` - Only show the closer button on hover.
        - `sticker: true` - Provide a button for the user to manually stick the notice.
        - `sticker_hover: true` - Only show the sticker button on hover.
        - `hide: true` - After a delay, remove the notice.
        - `delay: 8000` - Delay in milliseconds before the notice is removed.
        - `mouse_reset: true` - Reset the hide timer if the mouse moves over the notice.
        - `remove: true` - Remove the notice's elements from the DOM after it is removed.
        - `insert_brs: true` - Change new lines to br tags.
        """
        obj = {}
        for k, v in kwds.iteritems():
            obj[k] = sage_salvus.jsonable(v)
        self.javascript("$.pnotify(obj)", once=True, obj=obj)

    def execute_javascript(self, code, coffeescript=False, obj=None):
        """
        Tell the browser to execute javascript.  Basically the same as
        salvus.javascript with once=True (the default), except this
        isn't tied to a particular cell.  There is a worksheet object
        defined in the scope of the evaluation.

        See the docs for the top-level javascript function for more details.
        """
        self._conn.send_json(message.execute_javascript(code,
            coffeescript=coffeescript, obj=json.dumps(obj,separators=(',', ':'))))

    def execute_coffeescript(self, *args, **kwds):
        """
        This is the same as salvus.execute_javascript, but with coffeescript=True.

        See the docs for the top-level javascript function for more details.
        """
        kwds['coffeescript'] = True
        self.execute_javascript(*args, **kwds)

    def _cython(self, filename, **opts):
        """
        Return module obtained by compiling the Cython code in the
        given file.

        INPUT:

           - filename -- name of a Cython file
           - all other options are passed to sage.misc.cython.cython unchanged,
             except for use_cache which defaults to True (instead of False)

        OUTPUT:

           - a module
        """
        if 'use_cache' not in opts:
            opts['use_cache'] = True
        import sage.misc.cython
        modname, path = sage.misc.cython.cython(filename, **opts)
        import sys
        try:
            sys.path.insert(0,path)
            module = __import__(modname)
        finally:
            del sys.path[0]
        return module

    def _import_code(self, content, **opts):
        while True:
            py_file_base = uuid().replace('-','_')
            if not os.path.exists(py_file_base + '.py'):
                break
        try:
            open(py_file_base+'.py', 'w').write(content)
            import sys
            try:
                sys.path.insert(0, os.path.abspath('.'))
                mod = __import__(py_file_base)
            finally:
                del sys.path[0]
        finally:
            os.unlink(py_file_base+'.py')
            os.unlink(py_file_base+'.pyc')
        return mod

    def _sage(self, filename, **opts):
        import sage.misc.preparser
        content = "from sage.all import *\n" + sage.misc.preparser.preparse_file(open(filename).read())
        return self._import_code(content, **opts)

    def _spy(self, filename, **opts):
        import sage.misc.preparser
        content = "from sage.all import Integer, RealNumber, PolynomialRing\n" + sage.misc.preparser.preparse_file(open(filename).read())
        return self._import_code(content, **opts)

    def _py(self, filename, **opts):
        return __import__(filename)

    def require(self, filename, **opts):
        if not os.path.exists(filename):
            raise ValueError("file '%s' must exist"%filename)
        base,ext = os.path.splitext(filename)
        if ext == '.pyx' or ext == '.spyx':
            return self._cython(filename, **opts)
        if ext == ".sage":
            return self._sage(filename, **opts)
        if ext == ".spy":
            return self._spy(filename, **opts)
        if ext == ".py":
            return self._py(filename, **opts)
        raise NotImplementedError("require file of type %s not implemented"%ext)

    def typeset_mode(self, on=True):
        sage_salvus.typeset_mode(on)

    def project_info(self):
        """
        Return a dictionary with information about the project in which this code is running.

        EXAMPLES::

            sage: salvus.project_info()
            {"stdout":"{u'project_id': u'...', u'location': {u'username': u'teaAuZ9M', u'path': u'.', u'host': u'localhost', u'port': 22}, u'base_url': u'/...'}\n"}
        """
        return INFO


Salvus.pdf.__func__.__doc__ = sage_salvus.show_pdf.__doc__

def execute(conn, id, code, data, cell_id, preparse, message_queue):

    salvus = Salvus(conn=conn, id=id, data=data, message_queue=message_queue, cell_id=cell_id)
    salvus.start_executing()

    try:
        # initialize the salvus output streams
        streams = (sys.stdout, sys.stderr)
        sys.stdout = BufferedOutputStream(salvus.stdout)
        sys.stderr = BufferedOutputStream(salvus.stderr)
        try:
            # initialize more salvus functionality
            sage_salvus.salvus = salvus
            namespace['sage_salvus'] = sage_salvus
        except:
            traceback.print_exc()

        if salvus._prefix:
            if not code.startswith("%"):
                code = salvus._prefix + '\n' + code

        if salvus._postfix:
            code += '\n' + salvus._postfix

        salvus.execute(code, namespace=namespace, preparse=preparse)

    finally:
        # there must be exactly one done message, unless salvus._done is False.
        if sys.stderr._buf:
            if sys.stdout._buf:
                sys.stdout.flush()
            sys.stderr.flush(done=salvus._done)
        else:
            sys.stdout.flush(done=salvus._done)
        (sys.stdout, sys.stderr) = streams


def drop_privileges(id, home, transient, username):
    gid = id
    uid = id
    if transient:
        os.chown(home, uid, gid)
    os.setgid(gid)
    os.setuid(uid)
    os.environ['DOT_SAGE'] = home
    mpl = os.environ['MPLCONFIGDIR']
    os.environ['MPLCONFIGDIR'] = home + mpl[5:]
    os.environ['HOME'] = home
    os.environ['IPYTHON_DIR'] = home
    os.environ['USERNAME'] = username
    os.environ['USER'] = username
    os.chdir(home)

    # Monkey patch the Sage library and anything else that does not
    # deal well with changing user.  This sucks, but it is work that
    # simply must be done because we're not importing the library from
    # scratch (which would take a long time).
    import sage.misc.misc
    sage.misc.misc.DOT_SAGE = home + '/.sage/'


class MessageQueue(list):
    def __init__(self, conn):
        self.queue = []
        self.conn  = conn

    def __repr__(self):
        return "Sage Server Message Queue"

    def __getitem__(self, i):
        return self.queue[i]

    def __delitem__(self, i):
        del self.queue[i]

    def next_mesg(self):
        """
        Remove oldest message from the queue and return it.
        If the queue is empty, wait for a message to arrive
        and return it (does not place it in the queue).
        """
        if self.queue:
            return self.queue.pop()
        else:
            return self.conn.recv()

    def recv(self):
        """
        Wait until one message is received and enqueue it.
        Also returns the mesg.
        """
        mesg = self.conn.recv()
        self.queue.insert(0,mesg)
        return mesg



def session(conn):
    """
    This is run by the child process that is forked off on each new
    connection.  It drops privileges, then handles the complete
    compute session.

    INPUT:

    - ``conn`` -- the TCP connection
    """
    mq = MessageQueue(conn)

    pid = os.getpid()

    # seed the random number generator(s)
    import sage.all; sage.all.set_random_seed()
    import random; random.seed(sage.all.initial_seed())

    # get_memory_usage is (by ignorant design) not aware of being forked... (should post a trac ticket!)
    import sage.misc.getusage
    sage.misc.getusage._proc_status = "/proc/%s/status"%os.getpid()

    cnt = 0
    while True:
        try:
            typ, mesg = mq.next_mesg()

            #print 'INFO:child%s: received message "%s"'%(pid, mesg)
            log("handling message ", truncate_text(unicode8(mesg), 256))
            event = mesg['event']
            if event == 'terminate_session':
                return
            elif event == 'execute_code':
                try:
                    execute(conn          = conn,
                            id            = mesg['id'],
                            code          = mesg['code'],
                            data          = mesg.get('data',None),
                            cell_id       = mesg.get('cell_id',None),
                            preparse      = mesg['preparse'],
                            message_queue = mq)
                except Exception, err:
                    log("ERROR -- exception raised '%s' when executing '%s'"%(err, mesg['code']))
            elif event == 'introspect':
                try:
                    introspect(conn=conn, id=mesg['id'], line=mesg['line'], preparse=mesg['preparse'])
                except:
                    pass
            else:
                raise RuntimeError("invalid message '%s'"%mesg)
        except:
            # When hub connection dies, loop goes crazy.
            # Unfortunately, just catching SIGINT doesn't seem to
            # work, and leads to random exits during a
            # session. Howeer, when connection dies, 10000 iterations
            # happen almost instantly.  Ugly, but it works.
            cnt += 1
            if cnt > 10000:
                sys.exit(0)
            else:
                pass


def introspect(conn, id, line, preparse):
    salvus = Salvus(conn=conn, id=id) # so salvus.[tab] works -- note that Salvus(...) modifies namespace.
    z = sage_parsing.introspect(line, namespace=namespace, preparse=preparse)
    if z['get_completions']:
        mesg = message.introspect_completions(id=id, completions=z['result'], target=z['target'])
    elif z['get_help']:
        mesg = message.introspect_docstring(id=id, docstring=z['result'], target=z['expr'])
    elif z['get_source']:
        mesg = message.introspect_source_code(id=id, source_code=z['result'], target=z['expr'])
    conn.send_json(mesg)

def handle_session_term(signum, frame):
    while True:
        try:
            pid, exit_status = os.waitpid(-1, os.WNOHANG)
        except:
            return
        if not pid: return

secret_token = None
secret_token_path = os.path.join(os.environ['SAGEMATHCLOUD'], 'data/secret_token')

def unlock_conn(conn):
    global secret_token
    if secret_token is None:
        try:
            secret_token = open(secret_token_path).read()
        except:
            conn.send('n')
            conn.send("Unable to accept connection, since Sage server doesn't yet know the secret token; unable to read from '%s'"%secret_token_path)
            conn.close()

    n = len(secret_token)
    token = ''
    while len(token) < n:
        token += conn.recv(n)
        if token != secret_token[:len(token)]:
            break # definitely not right -- don't try anymore
    if token != secret_token:
        conn.send('n')  # no -- invalid login
        conn.send("Invalid secret token.")
        conn.close()
        return False
    else:
        conn.send('y') # yes -- valid login
        return True

def serve_connection(conn):
    global PID
    PID = os.getpid()
    # First the client *must* send the secret shared token. If they
    # don't, we return (and the connection will have been destroyed by
    # unlock_conn).
    log("Serving a connection")
    log("Waiting for client to unlock the connection...")
    # TODO -- put in a timeout (?)
    if not unlock_conn(conn):
        log("Client failed to unlock connection. Dumping them.")
        return
    log("Connection unlocked.")

    try:
        conn = ConnectionJSON(conn)
        typ, mesg = conn.recv()
        log("Received message %s"%mesg)
    except Exception, err:
        log("Error receiving message: %s (connection terminated)"%str(err))
        raise

    if mesg['event'] == 'send_signal':
        if mesg['pid'] == 0:
            log("invalid signal mesg (pid=0)")
        else:
            log("Sending a signal")
            os.kill(mesg['pid'], mesg['signal'])
        return
    if mesg['event'] != 'start_session':
        log("Received an unknown message event = %s; terminating session."%mesg['event'])
        return

    log("Starting a session")
    desc = message.session_description(os.getpid())
    log("child sending session description back: %s"%desc)
    conn.send_json(desc)
    session(conn=conn)

def serve(port, host):
    #log.info('opening connection on port %s', port)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    # check for children that have finished every few seconds, so
    # we don't end up with zombies.
    s.settimeout(5)

    s.bind((host, port))
    log('Sage server %s:%s'%(host, port))

    # Enabling the following signal completely breaks subprocess pexpect in many cases, which is
    # obviously totally unacceptable.
    #signal.signal(signal.SIGCHLD, handle_session_term)

    def init_library():
        tm = time.time()
        log("pre-importing the sage library...")

        # FOR testing purposes.
        ##log("fake 40 second pause to slow things down for testing....")
        ##time.sleep(40)
        ##log("done with pause")

        # Monkey patching interact using the new and improved Salvus
        # implementation of interact.
        import sagenb.notebook.interact
        sagenb.notebook.interact.interact = sage_salvus.interact

        # Actually import sage now.  This must happen after the interact
        # import because of library interacts.
        log("import sage...")
        import sage.all

        # Monkey patch the html command.
        import sage.interacts.library
        sage.all.html = sage.misc.html.html = sage.interacts.library.html = sage_salvus.html

        # Set a useful figsize default; the matplotlib one is not notebook friendly.
        import sage.plot.graphics
        sage.plot.graphics.Graphics.SHOW_OPTIONS['figsize']=[8,4]

        # Monkey patch latex.eval, so that %latex works in worksheets
        sage.misc.latex.latex.eval = sage_salvus.latex0

        # Plot, integrate, etc., -- so startup time of worksheets is minimal.

        for cmd in ['from sage.all import *',
                    'from sage.calculus.predefined import x',
                    'import scipy',
                    'import sympy',
                    'import pylab',
                    "plot(sin).save('%s/a.png'%os.environ['SAGEMATHCLOUD'], figsize=2)",
                    'integrate(sin(x**2),x)']:
            log(cmd)
            exec cmd in namespace

        global pylab
        pylab = namespace['pylab']     # used for clearing

        log('imported sage library and other components in %s seconds'%(time.time() - tm))

        for k,v in sage_salvus.interact_functions.iteritems():
            namespace[k] = sagenb.notebook.interact.__dict__[k] = v

        namespace['_salvus_parsing'] = sage_parsing

        for name in ['coffeescript', 'javascript', 'time', 'timeit', 'capture', 'cython',
                     'script', 'python', 'python3', 'perl', 'ruby', 'sh', 'prun', 'show', 'auto',
                     'hide', 'hideall', 'cell', 'fork', 'exercise', 'dynamic', 'var',
                     'reset', 'restore', 'md', 'load', 'runfile', 'typeset_mode', 'default_mode',
                     'sage_chat', 'fortran', 'magics', 'go', 'julia', 'pandoc', 'wiki',
                     'mediawiki', 'help']:
            namespace[name] = getattr(sage_salvus, name)

        # alias pretty_print_default to typeset_mode, since sagenb has/uses that.
        namespace['pretty_print_default'] = namespace['typeset_mode']
        # and monkey patch it
        sage.misc.latex.pretty_print_default = namespace['pretty_print_default']

        sage_salvus.default_namespace = dict(namespace)
        log("setup namespace with extra functions")

        # Sage's pretty print is ancient and a mess.
        sage.all.pretty_print = sage.misc.latex.pretty_print = namespace['pretty_print'] = namespace['show']

        # this way client code can tell it is running as a Sage Worksheet.
        namespace['__SAGEWS__'] = True

    log("Initialize sage library.")
    init_library()

    t = time.time()
    s.listen(128)
    i = 0

    log("Write to file name of port we are now listening on.", args.port)
    try:
        open(os.path.join(DATA_PATH, "sage_server.port"),'w').write(str(args.port))
    except Exception, err:
        log("Not writing sage_server.port file --", err)

    children = {}
    log("Starting server listening for connections")
    try:
        while True:
            i += 1
            #print i, time.time()-t, 'cps: ', int(i/(time.time()-t))
            # do not use log.info(...) in the server loop; threads = race conditions that hang server every so often!!
            try:
                if children:
                    for pid in children.keys():
                        if os.waitpid(pid, os.WNOHANG) != (0,0):
                            log("subprocess %s terminated, closing connection"%pid)
                            conn.close()
                            del children[pid]

                try:
                    conn, addr = s.accept()
                    log("Accepted a connection from", addr)
                except:
                    # this will happen periodically since we did s.settimeout above, so
                    # that we wait for children above periodically.
                    continue
            except socket.error, msg:
                continue
            child_pid = os.fork()
            if child_pid: # parent
                log("forked off child with pid %s to handle this connection"%child_pid)
                children[child_pid] = conn
            else:
                # child
                global PID
                PID = os.getpid()
                log("child process, will now serve this new connection")
                serve_connection(conn)

        # end while
    except Exception, err:
        log("Error taking connection: ", err)
        traceback.print_exc(file=sys.stdout)
        #log.error("error: %s %s", type(err), str(err))

    finally:
        log("closing socket")
        #s.shutdown(0)
        s.close()

def run_server(port, host, pidfile):
    if pidfile:
        open(pidfile,'w').write(str(os.getpid()))
    if logfile:
        #log.addHandler(logging.FileHandler(logfile))
        pass
    log("run_server: port=%s, host=%s, pidfile='%s', logfile='%s'"%(port, host, pidfile, logfile))
    try:
        serve(port, host)
    finally:
        if pidfile:
            os.unlink(pidfile)

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Run Sage server")
    parser.add_argument("-p", dest="port", type=int, default=0,
                        help="port to listen on (default: 0); 0 = automatically allocated; saved to $SAGEMATHCLOUD/data/sage_server.port")
    parser.add_argument("-l", dest='log_level', type=str, default='INFO',
                        help="log level (default: INFO) useful options include WARNING and DEBUG")
    parser.add_argument("-d", dest="daemon", default=False, action="store_const", const=True,
                        help="daemon mode (default: False)")
    parser.add_argument("--host", dest="host", type=str, default='127.0.0.1',
                        help="host interface to bind to -- default is 127.0.0.1")
    parser.add_argument("--pidfile", dest="pidfile", type=str, default='',
                        help="store pid in this file")
    parser.add_argument("--logfile", dest="logfile", type=str, default='',
                        help="store log in this file (default: '' = don't log to a file)")
    parser.add_argument("-c", dest="client", default=False, action="store_const", const=True,
                        help="run in test client mode number 1 (command line)")
    parser.add_argument("--hostname", dest="hostname", type=str, default='',
                        help="hostname to connect to in client mode")
    parser.add_argument("--portfile", dest="portfile", type=str, default='',
                        help="write port to this file")

    args = parser.parse_args()

    if args.daemon and not args.pidfile:
        print "%s: must specify pidfile in daemon mode"%sys.argv[0]
        sys.exit(1)

    if args.log_level:
        pass
        #level = getattr(logging, args.log_level.upper())
        #log.setLevel(level)

    if args.client:
        client1(port=args.port if args.port else int(open(args.portfile).read()), hostname=args.hostname)
        sys.exit(0)

    if not args.port:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.bind(('',0)) # pick a free port
        args.port = s.getsockname()[1]
        DATA_PATH = os.path.join(os.environ['SAGEMATHCLOUD'], "data")
        if not os.path.exists(DATA_PATH):
            os.makedirs(DATA_PATH)
        del s

    if args.portfile:
        open(args.portfile,'w').write(str(args.port))

    pidfile = os.path.abspath(args.pidfile) if args.pidfile else ''
    logfile = os.path.abspath(args.logfile) if args.logfile else ''
    if logfile:
        LOGFILE = logfile
        open(LOGFILE, 'w')  # for now we clear it on restart...
        log("setting logfile to %s"%LOGFILE)

    main = lambda: run_server(port=args.port, host=args.host, pidfile=pidfile)
    if args.daemon and args.pidfile:
        import daemon
        daemon.daemonize(args.pidfile)
        main()
    else:
        main()
