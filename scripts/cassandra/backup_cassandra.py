import os

def cmd(s):
    print s
    return os.popen(s).read()

def cmd2(s):
    print s
    if os.system(s):
        raise RuntimeError
    return

def backup_cassandra(dc, hosts):

    BUP_DIR = "/backups/cassandra-dc%s"%(dc,)
    os.environ['BUP_DIR'] = BUP_DIR
    if not os.path.exists(BUP_DIR):
        os.makedirs(BUP_DIR)

    cmd("bup init")

    for host in hosts:
        print host

        cmd("time bup on %s init"%host)

        # Find all snapshot and backup directories, except the MASSIVE hints directory, which we do not care about.
        a = cmd("ssh %s 'find /mnt/cassandra/lib/data/ -type d |grep /snapshots | grep -v hints '"%host).splitlines()
        a += cmd("ssh %s 'find /mnt/cassandra/lib/data/ -type d |grep /backups | grep -v hints '"%host).splitlines()

        # Don't consider paths that are just longer versions of other paths
        b = []
        for p in a:
            for s in a:
                 if len(s) < len(p) and s == p[:len(s)]:
                     # do not include p
                     break
            b.append(p)
        paths = ' '.join(b)

        cmd2("time bup on %s index %s"%(host, paths))
        try:
            cmd2("time bup on %s save -n %s %s"%(host, host, paths))
        except Exception, msg:
            # This is expected to happen sometimes due to  files vanishing, changing, etc.
            print msg
