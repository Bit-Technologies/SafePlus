#!/usr/bin/env python
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



"""

BUP/ZFS-based project storage system

The basic idea:

   - a bup repo with snapshot history of a project is stored on k machines in each data center, with a way to sync repos
   - live files are also stored on those same k machines in a directory as part of one big dedup'd and compressed zpool, which is snapshotted regularly
   - all internode/interdata-center replication is done via rsync
   - Loss of files is very hard, because the files and their history is contained in:
            (1) the bup repos  (backed up offsite)
            (2) the snapshots of the big single shared zfs filesystem (not backed up)
     Note that project history may move when new nodes are added, due to consistent hashing.  But the zfs snapshots still exist.


INSTALL:

In visudo:

    salvus ALL=(ALL) NOPASSWD: /usr/local/bin/bup_storage.py *

Install script:

     cp /home/salvus/salvus/salvus/scripts/bup_storage.py /usr/local/bin/
     chown root:salvus /usr/local/bin/bup_storage.py
     chmod ug+rx /usr/local/bin/bup_storage.py
     chmod og-w /usr/local/bin/bup_storage.py
     chmod o-x /usr/local/bin/bup_storage.py


Setup Pool:


export POOL=bup
# export POOL=pool
#zpool create -f $POOL /dev/sdb   # on gce
#zpool create -f $POOL /dev/vdb
zfs create $POOL/projects
zfs set mountpoint=/projects $POOL/projects
zfs set dedup=on $POOL/projects
zfs set compression=lz4 $POOL/projects
zfs create $POOL/bups
zfs set mountpoint=/bup/bups $POOL/bups
chmod og-rwx /bup/bups

zfs create $POOL/scratch
zfs set mountpoint=/scratch $POOL/scratch
zfs set compression=lz4 $POOL/scratch
chmod a+rwx /scratch

zfs create $POOL/conf
zfs set mountpoint=/bup/conf $POOL/conf
zfs set compression=lz4 $POOL/conf
chmod og-rwx /bup/conf
chown salvus. /bup/conf

chmod a+rx /bup

"""

# How frequently bup watch dumps changes to disk.
BUP_WATCH_SAVE_INTERVAL_MS=60000
USE_BUP_WATCH = False

# If UNSAFE_MODE=False, we only provide a restricted subset of options.  When this
# script will be run via sudo, it is useful to minimize what it is able to do, e.g.,
# there is no reason it should have easy command-line options to overwrite any file
# on the system with arbitrary content.
UNSAFE_MODE=False

import argparse, hashlib, math, os, random, shutil, socket, string, sys, time, uuid, json, signal, math, pwd, codecs, re
from subprocess import Popen, PIPE
from uuid import UUID, uuid4

# Flag to turn off all use of quotas, since it will take a while to set these up after migration.
QUOTAS_ENABLED=True
QUOTAS_OVERRIDE=0  # 0 = don't override

USERNAME =  pwd.getpwuid(os.getuid())[0]

# If using ZFS
ZPOOL          = 'bup'   # must have ZPOOL/bups and ZPOOL/projects filesystems

# The path where bup repos are stored
BUP_PATH       = '/bup/bups'

# The path where project working files appear
PROJECTS_PATH  = '/projects'

# Default account settings

DEFAULT_SETTINGS = {
    'disk'       : 5000,     # default disk in megabytes
    'scratch'    : 15000,    # default disk quota on /scratch
    'memory'     : 8,        # memory in gigabytes
    'cpu_shares' : 256,
    'cores'      : 1,
    'login_shell': '/bin/bash',
    'mintime'    : 60*60*3,  # default = 3 hours idle (no save) time before kill
    'inode'      : 200000,  # not used with ZFS
    'network'    : False
}

BWLIMIT = 20000

FILESYSTEM = 'zfs'   # 'zfs' or 'ext4'

if FILESYSTEM == 'ext4':
    if not os.path.exists(BUP_PATH):
        cmd("/bin/mkdir -p %s; chmod og-rwx %s"%(BUP_PATH, BUP_PATH))

    if not os.path.exists(PROJECTS_PATH):
        cmd("/bin/mkdir -p %s; chmod og+rx %s"%(PROJECTS_PATH, PROJECTS_PATH))


# Make sure to copy: 'cp -rv ~/salvus/salvus/scripts/skel/.sagemathcloud/data /home/salvus/salvus/salvus/local_hub_template/"
SAGEMATHCLOUD_TEMPLATE = "/home/salvus/salvus/salvus/local_hub_template/"

BASHRC_TEMPLATE        = "/home/salvus/salvus/salvus/scripts/skel/.bashrc"
BASH_PROFILE_TEMPLATE  = "/home/salvus/salvus/salvus/scripts/skel/.bash_profile"

#SSH_ACCESS_PUBLIC_KEY  = "/home/salvus/salvus/salvus/scripts/skel/.ssh/authorized_keys2"

def log(m, *args):
    if len(args):
        m = m%args
    sys.stderr.write(str(m)+'\n')
    sys.stderr.flush()


UID_WHITELIST = "/root/smc-iptables/uid_whitelist"
if not os.path.exists(UID_WHITELIST):
    try:
        open(UID_WHITELIST,'w').close()
    except Exception, err:
        log(err)



def print_json(s):
    print json.dumps(s, separators=(',',':'))

def uid(project_id):
    # We take the sha-512 of the uuid just to make it harder to force a collision.  Thus even if a
    # user could somehow generate an account id of their choosing, this wouldn't help them get the
    # same uid as another user.
    # 2^31-1=max uid which works with FUSE and node (and Linux, which goes up to 2^32-2).
    n = int(hashlib.sha512(project_id).hexdigest()[:8], 16)  # up to 2^32
    n /= 2  # up to 2^31
    return n if n>65537 else n+65537   # 65534 used by linux for user sync, etc.

def now():
    return time.strftime('%Y-%m-%dT%H:%M:%S')

def ensure_file_exists(src, target):
    if not os.path.exists(target):
        shutil.copyfile(src, target)
        s = os.stat(os.path.split(target)[0])
        if USERNAME == "root":
            os.chown(target, s.st_uid, s.st_gid)

def check_uuid(uuid):
    if UUID(uuid).version != 4:
        raise RuntimeError("invalid uuid")


def cmd(s, ignore_errors=False, verbose=2, timeout=None, stdout=True, stderr=True):
    if isinstance(s, list):
        s = [str(x) for x in s]
    if verbose >= 1:
        if isinstance(s, list):
            t = [x if len(x.split()) <=1  else "'%s'"%x for x in s]
            log(' '.join(t))
        else:
            log(s)
    t = time.time()

    mesg = "ERROR"
    if timeout:
        mesg = "TIMEOUT: running '%s' took more than %s seconds, so killed"%(s, timeout)
        def handle(*a):
            if ignore_errors:
                return mesg
            else:
                raise KeyboardInterrupt(mesg)
        signal.signal(signal.SIGALRM, handle)
        signal.alarm(timeout)
    try:
        out = Popen(s, stdin=PIPE, stdout=PIPE, stderr=PIPE, shell=not isinstance(s, list))
        x = out.stdout.read() + out.stderr.read()
        e = out.wait()  # this must be *after* the out.stdout.read(), etc. above or will hang when output large!
        if e:
            if ignore_errors:
                return (x + "ERROR").strip()
            else:
                raise RuntimeError(x)
        if verbose>=2:
            log("(%s seconds): %s"%(time.time()-t, x))
        elif verbose >= 1:
            log("(%s seconds)"%(time.time()-t))
        return x.strip()
    except IOError:
        return mesg
    finally:
        if timeout:
            signal.signal(signal.SIGALRM, signal.SIG_IGN)  # cancel the alarm

class Project(object):
    def __init__(self, project_id):
        try:
            u = uuid.UUID(project_id)
            assert u.get_version() == 4
            project_id = str(u)  # leaving off dashes still makes a valid uuid in python
        except (AssertionError, ValueError):
            raise RuntimeError("invalid project uuid='%s'"%project_id)
        self.project_id            = project_id
        self.uid                   = uid(project_id)
        self.gid                   = self.uid
        self.username              = self.project_id.replace('-','')
        self.groupname             = self.username
        self.bup_path              = os.path.join(BUP_PATH, project_id)
        self.conf_path             = os.path.join(self.bup_path, "conf")
        self.settings_path         = os.path.join(self.conf_path, "settings.json")
        self.replicas_path         = os.path.join(self.conf_path, "replicas.json")
        self.project_mnt           = os.path.join(PROJECTS_PATH, project_id)
        self.snap_mnt              = os.path.join(self.project_mnt, '.snapshots')
        self.touch_file            = os.path.join(self.bup_path, "conf", "touch")
        self.save_log              = os.path.join(self.bup_path, "conf", "save_log.json")
        self.HEAD                  = "%s/HEAD"%self.bup_path
        self.branch = open(self.HEAD).read().split('/')[-1].strip() if os.path.exists(self.HEAD) else 'master'

    def cmd(self, *args, **kwds):
        os.environ['BUP_DIR'] = self.bup_path
        return cmd(*args, **kwds)

    def __repr__(self):
        return "Project(%s)"%project_id

    def _log(self, funcname,**kwds):
        def f(mesg='',*args):
            log("%s(project_id=%s,%s): %s"%(funcname, self.project_id, kwds, mesg), *args)
        f()
        return f

    # this user_exists function isn't used or tested yet:
    def user_exists(self):
        """
        Returns True if the UNIX user for this project exists.
        """
        try:
            cmd(['id', self.username])  # id returns a non-zero status <==> user exists
            return True
        except RuntimeError:
            return False

    def create_user(self):
        self.create_home()
        login_shell = self.get_settings()['login_shell']
        if self.gid == self.uid:
            self.cmd(['/usr/sbin/groupadd', '-g', self.gid, '-o', self.username], ignore_errors=True)
        self.cmd(['/usr/sbin/useradd', '-u', self.uid, '-g', self.gid, '-o', self.username,
                  '-d', self.project_mnt, '-s', login_shell], ignore_errors=True)

    def delete_user(self):
        self.cmd(['/usr/sbin/userdel', self.username], ignore_errors=True)
        if self.gid == self.uid:
            self.cmd(['/usr/sbin/groupdel', self.username], ignore_errors=True)

    def start_daemons(self):
        self.cmd(['su', '-', self.username, '-c', 'cd .sagemathcloud; . sagemathcloud-env; ./start_smc'], timeout=30)

    def start_file_watch(self):
        pidfile = os.path.join(self.bup_path, "watch.pid")
        try:
            # there are a lot of valid reasons, e.g., due to sync/replication!, that this pidfile would be here when we do start.
            os.unlink(pidfile)
        except:
            pass

        self.cmd([
            "/usr/bin/bup", "watch",
            "--start",
            "--pidfile", pidfile,
            "--logfile", os.path.join(self.bup_path, "watch.log"),
            "--save-interval", BUP_WATCH_SAVE_INTERVAL_MS,
            "--xdev"]
            + self.exclude(self.project_mnt, prog='bup')
            + [self.project_mnt]
            )

    def stop_file_watch(self):
        self.cmd([
            "/usr/bin/bup", "watch",
            "--stop",
            "--pidfile", os.path.join(self.bup_path, "watch.pid")]
            )

    def start(self):
        self.init()
        self.create_home()
        self.delete_user()
        self.create_user()
        self.killall()
        self.settings()
        self.ensure_conf_files()
        self.touch()
        if USE_BUP_WATCH:
            log("starting file watch for user with id %s"%self.uid)
            self.start_file_watch()
        self.update_daemon_code()
        self.start_daemons()
        self.umount_snapshots()
        # TODO: remove this chown once (1) uid defn stabilizes -- after migration will go through all projects and properly chown.
        #self.chown_all()
        self.mount_snapshots()

    def chown_all(self):
        log = self._log("chown_all")
        for P in os.listdir(self.project_mnt):
            target = os.path.join(self.project_mnt, P)
            if target != self.snap_mnt:
                try:
                    self.chown(target)
                except Exception, err:
                    log("WARNING: %s"%err)

    def get_zfs_status(self):  # output is in BYTES!
        q = {}
        if not QUOTAS_ENABLED or QUOTAS_OVERRIDE:
            return q
        try:
            for x in ['userquota', 'userused']:
                for y in ['projects', 'scratch']:
                    q['%s-%s'%(x,y)] = int(cmd(['zfs', 'get', '-Hp', '%s@%s'%(x,self.uid), '%s/%s'%(ZPOOL,y)]).split()[2]) #//(2**20)
            return q
        except RuntimeError:
            return None

    def status(self, running=False):
        log = self._log("status")
        if running:
            s = {}
        else:
            s = {'username':self.username, 'uid':self.uid, 'gid':self.gid, 'settings':self.get_settings()}
            try:
                s['newest_snapshot'] = self.newest_snapshot()
                s['bup'] = 'working'
            except RuntimeError, mesg:
                mesg = str(mesg)
                if 'bup init' in mesg:
                    s['bup'] = 'uninitialized'  # it's just not initialized, which is no problem
                else:
                    s['bup'] = mesg
            s['load'] = [float(a.strip(',')) for a in os.popen('uptime').read().split()[-3:]]
            if FILESYSTEM == 'zfs':
                s['zfs'] = self.get_zfs_status()

        if self.username not in open('/etc/passwd').read():  # TODO: can be done better
            s['running'] = False
            return s

        try:
            t = self.cmd(['su', '-', self.username, '-c', 'cd .sagemathcloud; . sagemathcloud-env; ./status'], timeout=30)
            t = json.loads(t)
            s.update(t)
            s['running'] = bool(t.get('local_hub.pid',False))
            return s
        except Exception, msg:
            log("Error getting status -- %s"%msg)
            # important to actually let error propogate so that bup_server gets an error and knows things are
            # messed up, namely there is a user created, but the status command isn't working at all.  In this
            # case bup_server will know to try to kill this.
            raise

    def create_home(self):
        self._log('create_home')
        if not os.path.exists(self.project_mnt):
            self.makedirs(self.project_mnt)
        if USERNAME == "root":
            os.chown(self.project_mnt, self.uid, self.gid)

    def init(self):
        """
        Create user home directory and bup repo.
        """
        log = self._log("create")
        if not os.path.exists(os.path.join(self.bup_path,'objects')):
            self.cmd(['/usr/bin/bup', 'init'])
        self.create_home()
        self.makedirs(self.conf_path, chown=False)

    def set_branch(self, branch=''):
        if branch and branch != self.branch:
            self.branch = branch
            open(self.HEAD,'w').write("ref: refs/heads/%s"%branch)

    def checkout(self, snapshot='latest', branch=None):
        self.set_branch(branch)
        if not os.path.exists(self.project_mnt):
            self.makedirs(self.project_mnt)
            self.cmd(['/usr/bin/bup', 'restore', '%s/%s/'%(self.branch, snapshot), '--outdir', self.project_mnt])
            self.chown(self.project_mnt)
        else:
            src = os.path.join(self.snap_mnt, self.branch, snapshot)+'/'
            self.cmd(['rsync', '-saxH', '--delete-excluded', '--delete', self.exclude(src), src, self.project_mnt+'/'])

    def umount_snapshots(self):
        self.cmd(['fusermount', '-uz', self.snap_mnt], ignore_errors=True)

    def mount_snapshots(self):
        log = self._log('mount_snapshots')
        self.umount_snapshots()
        if os.path.exists(self.snap_mnt):
            shutil.rmtree(self.snap_mnt, ignore_errors=True)
        try:
            self.makedirs(self.snap_mnt)
            self.cmd(['bup', 'fuse', '-o', '--uid', self.uid, '--gid', self.gid, self.snap_mnt])
        except Exception, msg:
            # if there is no space to make the snapshot directory, user gets no snapshots.
            if 'Disk quota exceeded' in msg:
                log("nonfatal error -- %s"%msg)
            else:
                raise

    def touch(self):
        open(self.touch_file,'w')

    def last_touch_time(self):
        if os.path.exists(self.touch_file):
            return os.path.getmtime(self.touch_file)
        else:
            return time.time() # now -- since could be just creating project

    def stop(self, grace_s=0.5, only_if_idle=False):
        log = self._log('stop')
        if only_if_idle:
            log("checking if project is idle regarding saves")
            mintime = self.get_settings()['mintime']
            if mintime <= 0:
                log("nope -- it has infinite time")
            else:
                last = self.last_touch_time()
                time_since_last = time.time() - last
                log(" time_since_last = %s and mintime = %s"%( time_since_last , mintime))
                if  time_since_last  < mintime:
                    log("hasn't been long enough -- not stopping")
                    return

        self.killall(grace_s=grace_s)

        if USE_BUP_WATCH:
            log("stopping file watch for user with id %s"%self.uid)
            self.stop_file_watch()

        # So crontabs, remote logins, etc., won't happen... and user can't just get more free time via crontab. Not sure.
        # We need another state, which is that the project is "on" but daemons are all stopped and not using RAM.
        self.delete_user()
        self.unset_quota()
        self.umount_snapshots()

    def killall(self, grace_s=0.5):
        log = self._log('killall')
        log("killing all processes by user with id %s"%self.uid)
        MAX_TRIES=10
        # we use both kill and pkill -- pkill seems better in theory, but I've definitely seen it get ignored.
        for i in range(MAX_TRIES):
            self.cmd(['/usr/bin/killall', '-u', self.username], ignore_errors=True)
            self.cmd(['/usr/bin/pkill', '-u', self.uid], ignore_errors=True)
            time.sleep(grace_s)
            self.cmd(['/usr/bin/killall', '-9', '-u', self.username], ignore_errors=True)
            self.cmd(['/usr/bin/pkill', '-9', '-u', self.uid], ignore_errors=True)
            n = self.num_procs()
            log("kill attempt left %s procs"%n)
            if n == 0:
                return
        log("WARNING: failed to kill all procs after %s tries"%MAX_TRIES)


    def restart(self):
        self.stop()
        self.start()

    def pids(self):
        return [int(x) for x in cmd(['pgrep', '-u', self.uid], ignore_errors=True).replace('ERROR','').split()]

    def num_procs(self):
        return len(self.pids())

    def archive(self):
        """
        Remove the user's files, leaving only the bup repo.

        ** DANGEROUS. **

        This would be used when it is highly unlikely the project will ever be used again, e.g.,
        maybe when one deletes a project, and we want to keep it around for a while for archival
        purposes, just in case.
        """
        log = self._log("archive")
        self.stop()
        self.umount_snapshots()
        log("removing users files")
        shutil.rmtree(self.project_mnt)
        self.delete_user()

    def destroy(self):
        """
        *VERY DANGEROUS.*  Delete all traces of this project from this machine.
        """
        self.archive()
        shutil.rmtree(self.bup_path)

    def exclude(self, prefix, prog='rsync'):
        eprefix = re.escape(prefix)
        excludes = ['.sage/cache', '.fontconfig', '.sage/temp', '.zfs', '.npm', '.sagemathcloud', '.node-gyp', '.cache', '.forever', '.snapshots']
        exclude_rxs = []
        if prog == 'rsync':
            excludes.append('*.sage-backup')
        else: # prog == 'bup'
            exclude_rxs.append(r'.*\.sage\-backup')

        for i,x in enumerate(exclude_rxs):
            # escape the prefix for the regexs
            ex_len = len(re.escape(x))
            exclude_rxs[i] = re.escape(os.path.join(prefix, x))
            exclude_rxs[i] = exclude_rxs[i][:-ex_len]+x

        return ['--exclude=%s'%os.path.join(prefix, x) for x in excludes] + ['--exclude-rx=%s'%x for x in exclude_rxs]

    def save(self, path=None, timestamp=None, branch=None, sync=True, mnt=True, targets=""):
        """
        Save a snapshot.

        If sync is true, first does sync of live files, then creates the bup snapshot, then
        finally syncs data out and returns info about how successful that was.
        """
        log = self._log("save")
        self.touch()
        self.set_branch(branch)
        if path is None:
            path = self.project_mnt

        # Some countermeasures against bad users.
        try:
            for bad in open('/root/banned_files').read().split():
                if os.path.exists(os.path.join(self.project_mnt,bad)):
                    self.stop()
                    return {'files_saved' : 0}
        except Exception, msg:
            log("WARNING: non-fatal issue reading /root/banned_files file and shrinking user priority: %s"%msg)

        if sync:
            log("Doing first sync before save of the live files (ignoring any issues or errors)")
            self.sync(targets=targets, snapshots=False)

        # We ignore_errors below because unfortunately bup will return a nonzero exit code ("WARNING")
        # when it hits a fuse filesystem.   TODO: somehow be more careful that each
        if not USE_BUP_WATCH:
            self.cmd(["/usr/bin/bup", "index", "-x"] + self.exclude(path+'/') + [path], ignore_errors=True)

        what_changed = self.cmd(["/usr/bin/bup", "index", '-m', path],verbose=0).splitlines()
        files_saved = max(0, len(what_changed) - 1)      # 1 since always includes the directory itself
        result = {'files_saved' : files_saved}
        if files_saved > 0:

            if timestamp is None:
                # mark by the time when we actually start saving, not start indexing above.
                timestamp = int(time.time())

            result['timestamp'] = timestamp

            # It is important to still sync out, etc., even if there is an error.  Many errors are nonfatal, e.g., a file vanishes during save.
            try:
                self.cmd(["/usr/bin/bup", "save", "--strip", "-n", self.branch, '-d', timestamp, path])
            except RuntimeError, msg:
                log("WARNING: running bup failed with error: %s"%msg)
                result['error'] = str(msg)

            # record this so can properly describe the true "interval of time" over which the snapshot happened,
            # in case we want to for some reason...
            result['timestamp_end'] = int(time.time())

            result['bup_repo_size_kb'] = int(self.cmd(['du', '-s', '-x', '--block-size=KB', self.bup_path]).split()[0].split('k')[0])

            if mnt and path == self.project_mnt:
                self.mount_snapshots()

            if sync:
                result['sync'] = self.sync(targets=targets)

            # The save log turns out to be a really bad idea, at least implemented this way.
            # The problem is we quickly end up with one MASSIVE file; this is particularly painful
            # due to how replication works -- a single file saved here, and we have to copy gigabytes around!
            # We will find another way... e.g., one file for each save.
            #r = dict(result)
            #n = len(self.project_mnt)+1
            #r['files'] = [x[n:] for x in what_changed if len(x) > n]
            #try:
            #    codecs.open(self.save_log,'a',"utf-8-sig").write(json.dumps(r)+'\n')
            #except Exception, msg:
            #   # the save log is only a convenience -- not critical.
            #    log("WARNING: unable to write to save log -- %s"%msg)
        return result

    def tag(self, tag, delete=False):
        """
        Tag the latest commit to master or delete a tag.
        """
        if delete:
            self.cmd(["/usr/bin/bup", "tag", "-f", "-d", tag])
        else:
            self.cmd(["/usr/bin/bup", "tag", "-f", tag, self.branch])

    def newest_snapshot(self, branch=''):
        """
        Return newest snapshot in current branch or None if there are no snapshots yet.
        """
        v = self.snapshots(branch)
        if len(v) > 0:
            return v[-1]
        else:
            return None

    def snapshots(self, branch=''):
        """
        Return list of all snapshots in date order for the given branch.
        """
        if not branch:
            branch = self.branch
        if not os.path.exists(os.path.join(self.bup_path, 'refs', 'heads', branch)):
            # branch doesn't exist
            return []
        else:
            return self.cmd(["/usr/bin/bup", "ls", branch+'/'], verbose=0).split()[:-1]

    def branches(self):
        return {'branches':self.cmd("bup ls").split(), 'branch':self.branch}

    def cleanup(self):
        """
        Clean up the bup repo, replacing the large number of git pack files by a small number, deleting
        the bupindex cache, which can get really big, etc.

        After using this, you *must* do a destructive sync to all replicas!
        """
        self.cmd("cd %s; rm -f bupindex; rm -f objects/pack/*.midx; rm -f objects/pack/*.midx.tmp && rm -rf objects/*tmp && time git repack --max-pack-size=2g --window=0 --depth=0 -lad"%self.bup_path)

    def makedirs(self, path, chown=True):
        log = self._log('makedirs')
        if os.path.exists(path) and not os.path.isdir(path):
            log("removing %s"%path)
            os.unlink(path)
        if not os.path.exists(path):
            log("creating %s"%path)
            def makedirs(name):  # modified from os.makedirs to chown each newly created path segment
                head, tail = os.path.split(name)
                if not tail:
                    head, tail = os.path.split(head)
                if head and tail and not os.path.exists(head):
                    try:
                        makedirs(head)
                    except OSError, e:
                        # be happy if someone already created the path
                        if e.errno != errno.EEXIST:
                            raise
                    if tail == os.curdir:           # xxx/newdir/. exists if xxx/newdir exists
                        return
                os.mkdir(name, 0700)
                os.chown(name, self.uid, self.gid)
            makedirs(path)

    def update_daemon_code(self):
        log = self._log('update_daemon_code')
        self.create_home()
        target = '/%s/.sagemathcloud/'%self.project_mnt
        self.makedirs(target)
        self.cmd(["rsync", "-zaxHL", "--update", SAGEMATHCLOUD_TEMPLATE+"/", target])
        self.chown(target)

    def chown(self, path):
        self.cmd(["chown", "%s:%s"%(self.uid, self.gid), '-R', path])

    def ensure_file_exists(self, src, target):
        target = os.path.abspath(target)
        if not os.path.exists(target):
            self.makedirs(os.path.split(target)[0])
            shutil.copyfile(src, target)
            if USERNAME == "root":
                os.chown(target, self.uid, self.gid)

    def ensure_conf_files(self):
        log = self._log('ensure_conf_files')
        log("ensure there is a bashrc and bash_profile")
        self.create_home()
        self.ensure_file_exists(BASHRC_TEMPLATE, os.path.join(self.project_mnt,".bashrc"))
        self.ensure_file_exists(BASH_PROFILE_TEMPLATE, os.path.join(self.project_mnt,".bash_profile"))

    def get_settings(self):
        if not os.path.exists(self.conf_path):
            self.makedirs(self.conf_path, chown=False)
        if os.path.exists(self.settings_path):
            try:
                settings = json.loads(open(self.settings_path).read())
                for k, v in DEFAULT_SETTINGS.iteritems():
                    if k not in settings:
                        settings[k] = v
            except (ValueError, IOError), mesg:
                settings = dict(DEFAULT_SETTINGS)
        else:
            settings = dict(DEFAULT_SETTINGS)
        return settings

    def set_quota(self, disk, scratch):
        """
        Disk space quota
        """
        if not QUOTAS_ENABLED:
            return
        if QUOTAS_OVERRIDE:
            disk = scratch = QUOTAS_OVERRIDE
        cmd(['zfs', 'set', 'userquota@%s=%sM'%(self.uid, disk), '%s/projects'%ZPOOL])
        cmd(['zfs', 'set', 'userquota@%s=%sM'%(self.uid, scratch), '%s/scratch'%ZPOOL])

    def unset_quota(self):
        if not QUOTAS_ENABLED:
            return
        cmd(['zfs', 'set', 'userquota@%s=none'%self.uid, '%s/projects'%ZPOOL])
        cmd(['zfs', 'set', 'userquota@%s=none'%self.uid, '%s/scratch'%ZPOOL])


    def settings(self, memory  = None, cpu_shares  = None, cores   = None, disk    = None,
                       inode   = None, login_shell = None, scratch = None, mintime = None,
                       network = None):
        log = self._log('settings')
        log("configuring account...")

        settings = self.get_settings()

        if memory is not None:
            settings['memory'] = int(memory)
        memory = settings['memory']

        if cpu_shares is not None:
            settings['cpu_shares'] = int(cpu_shares)
        cpu_shares = settings['cpu_shares']

        if cores is not None:
            settings['cores'] = float(cores)
        cores = settings['cores']

        if disk is not None:
            settings['disk'] = int(disk)
        disk = settings['disk']

        if scratch is not None:
            settings['scratch'] = int(scratch)
        scratch = settings['scratch']

        if inode is not None:
            settings['inode'] = int(inode)
        inode = settings['inode']

        if mintime is not None:
            settings['mintime'] = int(mintime)
        mintime = settings['mintime']

        if network is not None:
            if isinstance(network, str):
                if network.lower() in ['0','false']:
                    network = False
                else:
                    network = True
            settings['network'] = bool(network)
        network = settings['network']

        if login_shell is not None and os.path.exists(login_shell):
            settings['login_shell'] = login_shell
        else:
            login_shell = settings['login_shell']

        try:
            s = json.dumps(settings)
            open(self.settings_path,'w').write(s)
            print s
        except IOError:
            pass

        # Set the quota
        self.set_quota(disk=disk, scratch=scratch)

        # Cgroups
        if cores <= 0:
            cfs_quota = -1  # no limit
        else:
            cfs_quota = int(100000*cores)

        # Special case -- if certain files are in the project, make them slow as molasses
        try:
            for bad in open('/root/banned_files').read().split():
                if os.path.exists(os.path.join(self.project_mnt, bad)):
                    cfs_quota = 1000
        except Exception, msg:
            log("WARNING: non-fatal issue reading banned_files file: %s"%msg)

        self.cmd(["cgcreate", "-g", "memory,cpu:%s"%self.username])
        open("/sys/fs/cgroup/memory/%s/memory.limit_in_bytes"%self.username,'w').write("%sG"%memory)
        open("/sys/fs/cgroup/cpu/%s/cpu.shares"%self.username,'w').write(str(cpu_shares))
        open("/sys/fs/cgroup/cpu/%s/cpu.cfs_quota_us"%self.username,'w').write(str(cfs_quota))

        # important -- using self.username instead of self.uid does NOT work reliably!
        z = "\n%s  cpu,memory  %s\n"%(self.username, self.username)
        cur = open("/etc/cgrules.conf").read() if os.path.exists("/etc/cgrules.conf") else ''

        if z not in cur:
            open("/etc/cgrules.conf",'a').write(z)

            # In Ubuntu 12.04 we used cgred, which doesn't exist in 14.04.  In 14.04, we're using PAM, so
            # classification happens automatically on login.
            try:
                self.cmd(['service', 'cgred', 'restart'])
            except:
                pass
            self.cgclassify()

        # open firewall whitelist for user if they have network access
        restart_firewall = False
        whitelisted_users = set([x.strip() for x in open(UID_WHITELIST).readlines()])
        uid = str(self.uid)
        if network and uid not in whitelisted_users:
            # add to whitelist and restart
            whitelisted_users.add(uid)
            restart_firewall = True
        elif not network and uid in whitelisted_users:
            # remove from whitelist and restart
            whitelisted_users.remove(uid)
            restart_firewall = True
        if restart_firewall:
            # THERE is a potential race condition here!  I would prefer to instead have files with names the
            # uid's in a subdirectory, or something...
            a = open(UID_WHITELIST,'w')
            a.write('\n'.join(whitelisted_users)+'\n')
            a.close()
            self.cmd(['/root/smc-iptables/restart.sh'])

    def cgclassify(self):
        try:
            pids = self.cmd("ps -o pid -u %s"%self.username, ignore_errors=False).split()[1:]
            self.cmd(["cgclassify"] + pids, ignore_errors=True)
            # ignore cgclassify errors, since processes come and go, etc.":
        except:
            # ps returns an error code if there are NO processes at all (a common condition).
            pids = []

    def sync(self, targets="", destructive=True, snapshots=True, union=False):
        """
        If union is True, uses the --update option of rsync to make the bup repos and working files
        on all replicas identical, namely the union of the newest versions of all files.  This is mainly
        used every-once-in-a-while as a sanity operation.   (It's intended application was only for migration.)
        This *CAN* loose bup commits -- we only get the commits of whoever had the newest master.  The
        data is in the git repo, but the references will be lost.  Tags won't be lost though.
        """
        log = self._log('sync')
        status = [{'host':h} for h in targets.split(',')]
        if not targets:
            log("nothing to sync to")
            return status
        log("syncing to %s"%targets)

        for s in status:
            t = time.time()
            try:
                self._sync(remote=s['host'], destructive=destructive, snapshots=snapshots, union=union)
            except Exception, err:
                s['error'] = str(err)
            s['time'] = time.time() - t

        if union:
            # do second stage of union
            for s in status:
                t = time.time()
                try:
                    self._sync(remote=s['host'], destructive=destructive, snapshots=snapshots, union2=True)
                except Exception, err:
                    s['error'] = s.get('error','') + str(err)
                s['time'] += time.time() - t

        return status

    def remote_is_ready(self, remote, port='22'):
        """
        Ensure that that /projects and /bup/bups are properly mounted on remote host.

        This code assumes that / on the remote host is *NOT* a ZFS filesystem.
        """
        s   = "stat -f -c %T /projects /bup/bups"
        out = self.cmd(["ssh", "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=no", '-p', port, 'root@'+remote, s], ignore_errors=True)
        return 'ext' not in out and 'zfs' in out  # properly mounted = mounted via ZFS in any way.

    def _sync(self, remote, destructive=True, snapshots=True, union=False, union2=False, rsync_timeout=120, bwlimit=BWLIMIT):
        """
        NOTE: sync is by default destructive on live files; on snapshots it isn't by default.

        If destructive is true, simply push from local to remote, overwriting anything that is remote.
        If destructive is false, pushes, then pulls, and makes a tag pointing at conflicts.
        """
        # NOTE: In the rsync's below we compress-in-transit the live project mount (-z),
        # but *NOT* the bup's, since they are already compressed.

        log = self._log('sync')
        log("syncing...")

        remote_bup_path = os.path.join(BUP_PATH, self.project_id)

        if ':' in remote:
            remote, port = remote.split(':')
        else:
            port = 22

        # Ensure that that /projects and /bup/bups are properly mounted on remote host before
        # doing the sync. This is critical, since we do not want to sync to a machine that has
        # booted up, but hasn't yet imported the ZFS pools.
        if not self.remote_is_ready(remote, port):
            raise RuntimeError("remote machine %s not ready to receive replicas"%remote)

        if union:
            log("union stage 1: gather files from outside")
            self.cmd(['rsync', '--update', '-zsaxH', '--timeout', rsync_timeout, '--bwlimit', bwlimit, "--ignore-errors"] + self.exclude('') +
                          ['-e', 'ssh -o StrictHostKeyChecking=no -p %s'%port,
                          "root@%s:%s/"%(remote, self.project_mnt),
                          self.project_mnt+'/'
                          ], ignore_errors=True)
            if snapshots:
                self.cmd(["rsync",  "--update", "-axH", '--timeout', rsync_timeout, '--bwlimit', bwlimit, "-e", 'ssh -o StrictHostKeyChecking=no -p %s'%port,
                          "root@%s:%s/"%(remote, remote_bup_path),
                          self.bup_path+'/'
                          ], ignore_errors=False)

            return

        if union2:
            log("union stage 2: push back to form union")
            self.cmd(['rsync', '--update', '-zsaxH', '--timeout', rsync_timeout, '--bwlimit', bwlimit, "--ignore-errors"] + self.exclude('') +
                          ['-e', 'ssh -o StrictHostKeyChecking=no -p %s'%port,
                          self.project_mnt+'/',
                          "root@%s:%s/"%(remote, self.project_mnt)
                          ], ignore_errors=True)
            if snapshots:
                self.cmd(["rsync",  "--update", "-axH", '--timeout', rsync_timeout, '--bwlimit', bwlimit, "-e", 'ssh -o StrictHostKeyChecking=no -p %s'%port,
                          self.bup_path+'/',
                          "root@%s:%s/"%(remote, remote_bup_path)
                          ], ignore_errors=False)
            return


        if os.path.exists(self.project_mnt):
            def f(ignore_errors):
                o = self.cmd(["rsync", "-zaxH", '--timeout', rsync_timeout, '--bwlimit', bwlimit, '--delete-excluded', "--delete", "--ignore-errors"] + self.exclude('') +
                          ['-e', 'ssh -o StrictHostKeyChecking=no -p %s'%port,
                          self.project_mnt+'/', "root@%s:%s/"%(remote, self.project_mnt)], ignore_errors=True)
                # include only lines that don't contain any of the following errors, since permission denied errors are standard with
                # FUSE mounts, and there is no way to make rsync not report them (despite the -x option above).
                # TODO: This is horrible code since a different rsync version could break it.
                v = ('\n'.join([a for a in o.splitlines() if a.strip() and 'ERROR' not in a and 'to the list of known hosts' not in a and 'see previous errors' not in a and 'failed: Permission denied' not in a and 'Command exited with non-zero status' not in a])).strip()
                if ignore_errors:
                    return v
                else:
                    if v:  # report the error
                        raise RuntimeError(v)

            e = f(ignore_errors=True)
            if QUOTAS_ENABLED and 'Disk quota exceeded' in e:
                self.cmd(["ssh", "-o", "StrictHostKeyChecking=no", '-p', port, 'root@'+remote,
                          'zfs set userquota@%s=%sM %s/projects'%(
                                        self.uid, QUOTAS_OVERRIDE if QUOTAS_OVERRIDE else self.get_settings()['disk'], ZPOOL)])
                f(ignore_errors=False)
            elif e:
                raise RuntimeError(e)

        if not snapshots:
            # nothing further to do -- we already sync'd the live files above, if we have any
            return

        if destructive:
            log("push so that remote=local: easier; have to do this after a recompact (say)")
            self.cmd(["rsync", "-axH", '--delete-excluded', "--delete", '--timeout', rsync_timeout, '--bwlimit', bwlimit, "-e", 'ssh -o StrictHostKeyChecking=no -p %s'%port,
                      self.bup_path+'/', "root@%s:%s/"%(remote, remote_bup_path)])
            return

        log("get remote heads")
        out = self.cmd(["ssh", "-o", "StrictHostKeyChecking=no", '-p', port, 'root@'+remote,
                        'grep -H \"\" %s/refs/heads/*'%remote_bup_path], ignore_errors=True)
        if 'such file or directory' in out:
            remote_heads = []
        else:
            if 'ERROR' in out:
                raise RuntimeError(out)
            remote_heads = []
            for x in out.splitlines():
                a, b = x.split(':')[-2:]
                remote_heads.append((os.path.split(a)[-1], b))
        log("sync from local to remote")
        self.cmd(["rsync", "-saxH", "-e", 'ssh -o StrictHostKeyChecking=no -p %s'%port, '--timeout', rsync_timeout, '--bwlimit', bwlimit,
                  self.bup_path + '/', "root@%s:%s/"%(remote, remote_bup_path)])
        log("sync from remote back to local")
        # the -v is important below!
        back = self.cmd(["rsync", "-saxH", "-e", 'ssh -o StrictHostKeyChecking=no -p %s'%port, '--timeout', rsync_timeout, '--bwlimit', bwlimit,
                         "root@%s:%s/"%(remote, remote_bup_path), self.bup_path + "/"]).splitlines()
        if remote_heads and len([x for x in back if x.endswith('.pack')]) > 0:
            log("there were remote packs possibly not available locally, so make tags that points to them")
            # so user can get their files if anything important got overwritten.
            tag = None
            for branch, id in remote_heads:
                # have we ever seen this commit?
                c = "%s/logs/refs/heads/%s"%(self.bup_path,branch)
                if not os.path.exists(c) or id not in open(c).read():
                    log("nope, never seen %s -- tag it."%branch)
                    tag = 'conflict-%s-%s'%(branch, time.strftime("%Y-%m-%d-%H%M%S"))
                    path = os.path.join(self.bup_path, 'refs', 'tags', tag)
                    open(path,'w').write(id)
            if tag is not None:
                log("sync back any tags")
                self.cmd(["rsync", "-saxH", "-e", 'ssh -o StrictHostKeyChecking=no -p %s'%port,
                          '--timeout', rsync_timeout, '--bwlimit', bwlimit, self.bup_path+'/', 'root@'+remote+'/'])

    def mount_remote(self, remote_host, project_id, mount_point='', remote_path='', read_only=False):
        """
        Make it so /projects/project_id/remote_path (which is on the remote host)
        appears as a local directory at /projects/project_id/mount_point.
        """
        log = self._log('mount_remote')
        log("mounting..")

        if not remote_host:
            raise RuntimeError("remote_host must be specified")
        try:
            u = uuid.UUID(project_id)
            assert u.get_version() == 4
            project_id = str(u)
        except (AssertionError, ValueError):
            raise RuntimeError("invalid project_id='%s'"%project_id)

        if not mount_point:
            m = os.path.join('projects', project_id, remote_path)
        else:
            m = mount_point.lstrip('/')
        mount_point = os.path.join(self.project_mnt, m)

        # If the point is already fuse or otherwise mounted but broken, then the os.path.exists(mount_point)
        # below returns false, etc.  So we always first unmount it, to start cleanly.
        try:
            self.umount_remote(mount_point)
        except RuntimeError:
            pass

        if not os.path.exists(mount_point):
            log("creating mount point")
            self.makedirs(mount_point)
        elif not os.path.isdir(mount_point):
            raise ValueError("mount_point='%s' must be a directory"%mount_point)

        remote_projects = "/projects-%s"%remote_host
        e = self.cmd(['stat', '-f', '-c', '%T', remote_projects], ignore_errors=True)
        if e != 'fuseblk':
            if 'endpoint is not connected' in e:
                self.cmd(["fusermount", "-z", "-u", remote_projects])
            log("mount the remote /projects filesystem using sshfs")
            if not os.path.exists(remote_projects):
                os.makedirs(remote_projects)
            self.cmd(['sshfs', remote_host + ':' + PROJECTS_PATH, remote_projects])

        remote_path = os.path.join(remote_projects, project_id)

        log("binding %s to %s"%(remote_path, mount_point))
        self.cmd(['bindfs'] + (['-o', 'ro'] if read_only else []) +
                 ['--create-for-user=%s'%uid(project_id), '--create-for-group=%s'%uid(project_id),
                  '-u', self.uid, '-g', self.gid, remote_path, mount_point])

    def umount_remote(self, mount_point):
        # the -z forces unmount even if filesystem is busy
        self.cmd(["fusermount", "-z", "-u", os.path.join(self.project_mnt, mount_point)])

    def mkdir(self, path):               # relative path in project; must resolve to be under PROJECTS_PATH/project_id
        project_id = self.project_id
        project_path = os.path.join(PROJECTS_PATH, project_id)
        abspath = os.path.abspath(os.path.join(project_path, path))
        if not abspath.startswith(project_path):
            raise RuntimeError("path (=%s) must be contained in project path %s"%(path, project_path))
        if not os.path.exists(abspath):
            self.makedirs(abspath)

    def copy_path(self,
                  path,                  # relative path to copy; must resolve to be under PROJECTS_PATH/project_id
                  target_hostname,       # list of hostnames (foo or foo:port) to copy files to
                  target_project_id,     # project_id of destination for files
                  target_path="",        # path into project; if "", defaults to path above.
                  overwrite_newer=False, # if True, newer files in target are copied over (otherwise, uses rsync's --update)
                  delete=False,          # if True, delete files in dest path not in source
                  rsync_timeout=120,
                  bwlimit=BWLIMIT
                 ):
        """
        Copy a path (directory or file) from one project to another.
        """
        #NOTES:
        #  1. We assume that PROJECTS_PATH is constant across all machines.
        #  2. We do the rsync, then change permissions.  This is either annoying or a feature,
        #     depending on your perspective, since it means the files
        #     aren't accessible until the copy completes.

        log = self._log("copy_path")

        if not target_hostname:
            raise RuntimeError("the target hostname must be specified")
        if not target_path:
            target_path = path

        # check that both UUID's are valid -- these will raise exception if there is a problem.
        check_uuid(target_project_id)

        project_id = self.project_id

        # parse out target rsync port, if necessary
        if ':' in target_hostname:
            target_hostname, target_port = target_hostname.split(':')
        else:
            target_port = '22'

        log("check that target is working (has ZFS mounts etc)")
        if not self.remote_is_ready(target_hostname, target_port):
            raise RuntimeError("remote machine %s:%s not ready to receive copy of path"%(target_hostname, target_port))

        # determine canonical absolute path to source
        project_path = os.path.join(PROJECTS_PATH, project_id)
        src_abspath = os.path.abspath(os.path.join(project_path, path))
        if not src_abspath.startswith(project_path):
            raise RuntimeError("source path must be contained in project path %s"%project_path)

        # determine canonical absolute path to target
        target_project_path = os.path.join(PROJECTS_PATH, target_project_id)
        target_abspath = os.path.abspath(os.path.join(target_project_path, target_path))
        if not target_abspath.startswith(target_project_path):
            raise RuntimeError("target path must be contained in target project path %s"%target_project_path)

        if os.path.isdir(src_abspath):
            src_abspath    += '/'
            target_abspath += '/'

        # handle options
        options = []
        if not overwrite_newer:
            options.append("--update")
        if delete:
            options.append("--delete")

        u = uid(target_project_id)
        try:
            # do the rsync
            v = (['rsync'] + options +
                     ['-zsax',                      # compressed, archive mode (so leave symlinks, etc.), don't cross filesystem boundaries
                      '--timeout', rsync_timeout,
                      '--bwlimit', bwlimit,
                      '--chown=%s:%s'%(u,u),
                      "--ignore-errors"] +
                     self.exclude('') +
                     ['-e', 'ssh -o StrictHostKeyChecking=no -p %s'%target_port,
                      src_abspath,
                      "%s:%s"%(target_hostname, target_abspath),
                     ])
            self.cmd(v)
        except Exception, mesg:
            log("rsync error: %s", mesg)
            raise


    # path = relative path in project; *must* resolve to be under PROJECTS_PATH/project_id or get an error.
    def directory_listing(self, path, hidden=True, time=True, start=0, limit=-1):
        project_id = self.project_id
        project_path = os.path.join(PROJECTS_PATH, project_id)
        abspath = os.path.abspath(os.path.join(project_path, path))
        if not abspath.startswith(project_path):
            raise RuntimeError("path (=%s) must be contained in project path %s"%(path, project_path))
        def get_file_mtime(name):
            try:
                # use lstat instead of stat or getmtime so this works on broken symlinks!
                return int(os.lstat(os.path.join(abspath, name)).st_mtime)
            except:
                # ?? This should never happen ??
                return 0

        def get_file_size(name):
            try:
                # same as above; use instead of os.path....
                return os.lstat(os.path.join(abspath, name)).st_size
            except:
                return -1


        listdir = os.listdir(abspath)
        result = {}
        if not hidden:
            listdir = [x for x in listdir if not x.startswith('.')]

        # Get list of (name, timestamp) pairs
        all = [(name, get_file_mtime(name)) for name in listdir]

        if time:
            # sort by time first with bigger times first, then by filename in normal order
            def f(a,b):
                if a[1] > b[1]:
                    return -1
                elif a[1] < b[1]:
                    return 0
                else:
                    return cmp(a[0],b[0])
            all.sort(f)
        else:
            all.sort()  # usual sort is fine

        # Limit and convert to objects
        all = all[start:]
        if limit > 0 and len(all) > limit:
            result['more'] = True
            all = all[:limit]


        files = dict([(name, {'name':name, 'mtime':mtime}) for name, mtime in all])
        sorted_names = [x[0] for x in all]

        # Fill in other OS information about each file
        #for obj in result:
        for name, info in files.iteritems():
            if os.path.isdir(os.path.join(abspath, name)):
                info['isdir'] = True
            else:
                info['size'] = get_file_size(name)


        result['files'] = [files[name] for name in sorted_names]
        return result


    # filename *must* resolve to be under PROJECTS_PATH/project_id or get an error; and it
    # must have size in bytes less than the given limit
    def read_file(self, path, maxsize):
        project_id = self.project_id
        project_path = os.path.join(PROJECTS_PATH, project_id)
        abspath = os.path.abspath(os.path.join(project_path, path))
        if not abspath.startswith(project_path):
            raise RuntimeError("path (=%s) must be contained in project path %s"%(path, project_path))
        size = os.lstat(abspath).st_size
        if size > maxsize:
            raise RuntimeError("path (=%s) must be at most %s bytes, but it is %s bytes"%(path, maxsize, size))
        return open(abspath).read()



if __name__ == "__main__":

    parser = argparse.ArgumentParser(description="Bup-backed SMC project storage system")
    subparsers = parser.add_subparsers(help='sub-command help')

    parser.add_argument("--zpool", help="the ZFS pool that has bup/projects in it", dest="zpool", default=ZPOOL, type=str)

    parser.add_argument("project_id", help="project id -- most subcommand require this", type=str)

    parser_init = subparsers.add_parser('init', help='init project repo and directory')
    parser_init.set_defaults(func=lambda args: project.init())

    parser_start = subparsers.add_parser('start', help='create user and setup the ~/.sagemathcloud filesystem')
    parser_start.set_defaults(func=lambda args: project.start())

    parser_status = subparsers.add_parser('status', help='get status of servers running in the project')
    parser_status.add_argument("--running", help="if given only return running part of status (easier to compute)",
                                   dest="running", default=False, action="store_const", const=True)
    def print_status(running):
        print json.dumps(project.status(running=running))
    parser_status.set_defaults(func=lambda args: print_status(args.running))

    parser_stop = subparsers.add_parser('stop', help='Kill all processes running as this user and delete user.')
    parser_stop.add_argument("--only_if_idle", help="only actually stop the project if the project is idle long enough",
                                   dest="only_if_idle", default=False, action="store_const", const=True)
    parser_stop.set_defaults(func=lambda args: project.stop(only_if_idle=args.only_if_idle))

    parser_restart = subparsers.add_parser('restart', help='restart servers')
    parser_restart.set_defaults(func=lambda args: project.restart())

    def do_save(*args, **kwds):
        print json.dumps(project.save(*args, **kwds))
    parser_save = subparsers.add_parser('save', help='save a snapshot then sync everything out')
    parser_save.add_argument("--targets", help="if given, a comma separated ip addresses of computers to replicate to NOT including the current machine", dest="targets", default="", type=str)
    parser_save.add_argument("--branch", dest="branch", help="save to specified branch (default: whatever current branch is); will change to that branch if different", type=str, default='')
    parser_save.set_defaults(func=lambda args: do_save(branch=args.branch, targets=args.targets))

    def do_sync(*args, **kwds):
        status = project.sync(*args, **kwds)
        print json.dumps(status)
    parser_sync = subparsers.add_parser('sync', help='sync with all replicas')
    parser_sync.add_argument("--targets", help="REQUIRED: a comma separated ip addresses of computers to replicate to NOT including the current machine", dest="targets", default="", type=str)
    parser_sync.add_argument("--destructive", help="sync, destructively overwriting all remote replicas (DANGEROUS)",
                                   dest="destructive", default=False, action="store_const", const=True)
    parser_sync.add_argument("--snapshots", help="include snapshots in sync",
                                   dest="snapshots", default=False, action="store_const", const=True)
    parser_sync.add_argument("--union", help="make it so bup and working directories on all replicas are the SAME (the union of newest files); this CAN loose particular bup snapshots",
                                   dest="union", default=False, action="store_const", const=True)
    parser_sync.set_defaults(func=lambda args: do_sync(targets            = args.targets,
                                                       destructive        = args.destructive,
                                                       snapshots          = args.snapshots,
                                                       union              = args.union))

    def do_copy_path(*args, **kwds):
        try:
            project.copy_path(*args, **kwds)
        except Exception, mesg:
            print json.dumps({"error":str(mesg)})
        else:
            print json.dumps({"ok":True})
    parser_copy_path = subparsers.add_parser('copy_path', help='copy a path from one project to another')
    parser_copy_path.add_argument("--target_hostname", help="REQUIRED: hostname of target machine for copy",
                                  dest="target_hostname", default='', type=str)
    parser_copy_path.add_argument("--target_project_id", help="REQUIRED: id of target project",
                                   dest="target_project_id", default="", type=str)
    parser_copy_path.add_argument("--path", help="relative path or filename in project",
                                  dest="path", default='', type=str)
    parser_copy_path.add_argument("--target_path", help="relative path into target project (defaults to --path)",
                                   dest="target_path", default='', type=str)
    parser_copy_path.add_argument("--overwrite_newer", help="if given, newer files in target are copied over",
                                   dest="overwrite_newer", default=False, action="store_const", const=True)
    parser_copy_path.add_argument("--delete", help="if given, delete files in dest path not in source",
                                   dest="delete", default=False, action="store_const", const=True)
    parser_copy_path.set_defaults(func=lambda args: do_copy_path(
                                                       path              = args.path,
                                                       target_hostname   = args.target_hostname,
                                                       target_project_id = args.target_project_id,
                                                       target_path       = args.target_path,
                                                       overwrite_newer   = args.overwrite_newer,
                                                       delete            = args.delete,
                                                       ))

    def do_mkdir(*args, **kwds):
        try:
            project.mkdir(*args, **kwds)
        except Exception, mesg:
            print json.dumps({"error":str(mesg)})
        else:
            print json.dumps({"ok":True})
    parser_mkdir = subparsers.add_parser('mkdir', help='make a path in a project')
    parser_mkdir.add_argument("--path", help="relative path in project", dest="path", default='', type=str)
    parser_mkdir.set_defaults(func=lambda args: do_mkdir(path = args.path))


    def do_directory_listing(*args, **kwds):
        try:
            print json.dumps(project.directory_listing(*args, **kwds))
        except Exception, mesg:
            print json.dumps({"error":str(mesg)})
    parser_directory_listing = subparsers.add_parser('directory_listing', help='list files (and info about them) in a directory in the project')
    parser_directory_listing.add_argument("--path", help="relative path in project", dest="path", default='', type=str)
    parser_directory_listing.add_argument("--hidden", help="if given, show hidden files",
                                   dest="hidden", default=False, action="store_const", const=True)
    parser_directory_listing.add_argument("--time", help="if given, sort by time with newest first",
                                   dest="time", default=False, action="store_const", const=True)
    parser_directory_listing.add_argument("--start", help="return only part of listing starting with this position (default: 0)",
                                   dest="start", default=0, type=int)
    parser_directory_listing.add_argument("--limit", help="if given, only return this many directory entries (default: -1)",
                                   dest="limit", default=-1, type=int)

    parser_directory_listing.set_defaults(func=lambda args: do_directory_listing(path = args.path, hidden=args.hidden, time=args.time, start=args.start, limit=args.limit))


    def do_read_file(*args, **kwds):
        try:
            print json.dumps(project.read_file(*args, **kwds))
        except Exception, mesg:
            print json.dumps({"error":str(mesg)})
    parser_read_file = subparsers.add_parser('read_file', help='read a file from disk')
    parser_read_file.add_argument("--path", help="relative path of a file in project (required)", dest="path", type=str)
    parser_read_file.add_argument("--maxsize", help="maximum file size to read; any bigger and instead give an error",
                                   dest="maxsize", default=3000000, type=int)

    parser_read_file.set_defaults(func=lambda args: do_read_file(path = args.path, maxsize=args.maxsize))


    parser_settings = subparsers.add_parser('settings', help='set settings for this user; also outputs settings in JSON')
    parser_settings.add_argument("--memory", dest="memory", help="memory settings in gigabytes",
                               type=int, default=None)
    parser_settings.add_argument("--cpu_shares", dest="cpu_shares", help="shares of the cpu",
                               type=int, default=None)
    parser_settings.add_argument("--cores", dest="cores", help="max number of cores (may be float)",
                               type=float, default=None)
    parser_settings.add_argument("--disk", dest="disk", help="working disk space in megabytes", type=int, default=None)
    parser_settings.add_argument("--network", dest="network", help="whether or not project has external network access", type=str, default=None)
    parser_settings.add_argument("--mintime", dest="mintime", help="minimum time in seconds before this project is automatically stopped if not saved", type=int, default=None)
    parser_settings.add_argument("--scratch", dest="scratch", help="scratch disk space in megabytes", type=int, default=None)
    parser_settings.add_argument("--inode", dest="inode", help="inode settings", type=int, default=None)
    parser_settings.add_argument("--login_shell", dest="login_shell", help="the login shell used when creating user", default=None, type=str)
    parser_settings.set_defaults(func=lambda args: project.settings(
                    memory=args.memory, cpu_shares=args.cpu_shares,
                    cores=args.cores, disk=args.disk, inode=args.inode, scratch=args.scratch,
                    login_shell=args.login_shell, mintime=args.mintime, network=args.network))

    parser_mount_remote = subparsers.add_parser('mount_remote',
                    help='Make it so /projects/project_id/remote_path (which is on the remote host) appears as a local directory at /projects/project_id/mount_point with ownership dynamically mapped so that the files appear owned by both projects (as they should).')
    parser_mount_remote.add_argument("--remote_host", help="", dest="remote_host",       default="",    type=str)
    parser_mount_remote.add_argument("--project_id",  help="", dest="remote_project_id", default="",    type=str)
    parser_mount_remote.add_argument("--mount_point", help="", dest="mount_point",       default="",    type=str)
    parser_mount_remote.add_argument("--remote_path", help="", dest="remote_path",       default="",    type=str)
    parser_mount_remote.add_argument("--read_only",   help="", dest="read_only",         default=False, action="store_const", const=True)
    parser_mount_remote.set_defaults(func=lambda args: project.mount_remote(
                                           remote_host = args.remote_host,
                                           project_id  = args.remote_project_id,
                                           mount_point = args.mount_point,
                                           remote_path = args.remote_path,
                                           read_only   = args.read_only)
                                     )

    parser_chown = subparsers.add_parser('chown', help="Ensure all files in the project have the correct owner and group.")
    parser_chown.set_defaults(func=lambda args: project.chown_all())

    parser_umount_remote = subparsers.add_parser('umount_remote')
    parser_umount_remote.add_argument("--mount_point", help="", dest="mount_point", default="", type=str)
    parser_umount_remote.set_defaults(func=lambda args: project.umount_remote(
                                           mount_point = args.mount_point))


    parser_tag = subparsers.add_parser('tag', help='tag the *latest* commit to master, or delete a tag')
    parser_tag.add_argument("tag", help="tag name", type=str)
    parser_tag.add_argument("--delete", help="delete the given tag",
                                   dest="delete", default=False, action="store_const", const=True)
    parser_tag.set_defaults(func=lambda args: project.tag(tag=args.tag, delete=args.delete))


    if UNSAFE_MODE:
        parser_archive = subparsers.add_parser('archive', help="*DANGEROUS*: Remove the user's files, leaving only the bup repo.")
        parser_archive.set_defaults(func=lambda args: project.archive())

        parser_destroy = subparsers.add_parser('destroy', help='**DANGEROUS**: Delete all traces of this project from this machine.')
        parser_destroy.set_defaults(func=lambda args: project.destroy())

    parser_snapshots = subparsers.add_parser('snapshots', help='output JSON list of snapshots of current branch')
    parser_snapshots.add_argument("--branch", dest="branch", help="show for given branch (by default the current one)", type=str, default='')
    parser_snapshots.set_defaults(func=lambda args: print_json(project.snapshots(branch=args.branch)))

    parser_branches = subparsers.add_parser('branches', help='output JSON {branches:[list of branches], branch:"name"}')
    parser_branches.set_defaults(func=lambda args: print_json(project.branches()))

    parser_checkout = subparsers.add_parser('checkout', help='checkout snapshot of project to working directory (DANGEROUS)')
    parser_checkout.add_argument("--snapshot", dest="snapshot", help="which tag or snapshot to checkout (default: latest)", type=str, default='latest')
    parser_checkout.add_argument("--branch", dest="branch", help="branch to checkout (default: whatever current branch is)", type=str, default='')
    parser_checkout.set_defaults(func=lambda args: project.checkout(snapshot=args.snapshot, branch=args.branch))

    args = parser.parse_args()

    t0 = time.time()
    ZPOOL = args.zpool
    project = Project(project_id  = args.project_id)
    args.func(args)
    log("total time: %s seconds"%(time.time()-t0))

