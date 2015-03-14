** Developer Documentation for SageMathCloud (SMC) **

These are extremely rough -- I literally haven't proof read them for a second!  Flow of consciousness.

 -- William Stein, March 14, 2015



# How to setup your development environment

## Premade virtual machine

There is a VirtualBox image with an environment pre-configured for SMC development at ... (TODO: create and provide url).

## On Ubuntu 14.10

In this section we explain how to install and run your own copy of SMC on Ubuntu 14.10.

1. Install Ubuntu 14.10, create a user named "salvus", and login as this user.
1. Clone the SMC Git repository (todo: change source repo to https://gihub.com/sagemathinc/)
        git clone https://github.com/sagemath/cloud salvus
1. Build everything.  This will download various packages (e.g., Node.js, Cassandra, etc.) from the web, then build and install them into ~/salvus/salvus/data/local/
        cd ~/salvus/
        ./build.py --build_all
1. Create a symbolic link:
        cd /usr/local/bin/
        sudo ln -s /home/salvus/salvus/salvus/scripts/bup_storage.py .
1. Once the build completes successfully, start SMC running as follows:
        cd ~/salvus/salvus
        . environ
        bup_server start
        ipython
        In [1]: import admin; reload(admin); a = admin.Services('conf/deploy_local/')
        In [2]: a.start('all')
1. In order to open Sage worksheets, you must also have Sage installed and available system-wide.
1. Create the database schema.  Right now I do this by copying and pasting from `~/salvus/salvus/db_schema.cql`.
1. Copy the bup server's port, location, and secret key into the database (todo).



## Within a SageMathCloud project

Not currently supported.  (I made this work once via port proxying/forwarding and making all ports very configurable, and supporting a base URL.  It would probably not be difficult to get it to work again.)



# The Architecture of SMC


## Services

The components of SMC are:
- **DNS** -- Domain name servers pointed at the stunnel servers, with geographic load balancing.  DNS should be setup with health checks, so that if https://ip-address/alive fails on one machine DNS stops serving to that machine temporarily.
- **stunnel servers** -- Processes that users connect to via SSL, which support encryption. The DNS for SMC resolves to the ip addresses of the stunnel servers.
- **haproxy servers** -- Proxy servers that must run on the same nodes as the stunnel servers. These load balance and proxy decrypted traffic between stunnel and the hub (dynamic node.js) and nginx (static http) servers, depending on the url.
- **nginx servers** -- static http servers, which serve the contents of ~/salvus/salvus/static.  Traffic is sent to them via haproxy, which also does the load balancing.
- **hub servers** -- (file: `hub.coffee`) dynamic webservers, which coordinate account information, and all traffic flow between users and projects.  There are many of these processes running in each data center (currently each hub can easily handle over 100 simultaneous persistent connection using a single core and a few hundred MB's of RAM). They are the only service with access to the database.
- **Cassandra database cluster** -- distributed multi-datacenter aware NoSQL database, with no single point of failure.  Stores account and project information, state information about all projects (where located), collaboration, who logs in and what files are being edited, the blob key:value store (images in worksheets), stats about how many clients are connected, and much more.  Does **NOT** store user files.
- **project servers** (files: `bup_server.coffee`, `scripts/bup_storage.py`) -- tcp server that is used by the hub to carry out actions related to running user projects, including creating a project, getting current stats, creating/deleting accounts on demand, reading public files/directories from projects, periodically killing idle projects, creating bup snapshots of projects, replicating (via rsync) projects to other hosts, limiting resources via cgroups, etc.
- **local hub servers** --
- **console servers** -
- **SageMath servers** -
- **IPython servers** -
- **compute machines** -
- **internal monitoring** -
- **external monitoring** --

In March 2015, on a typical day, here's an estimate of the number of instances of each of the above servers that are running:

- dns: 6 ip addresses served via Amazon Route 53.
- stunnel: 6 (3 in each data center = dc)
- haproxy: 6 (3 in each dc)
- nginx: 16 nginx servers (8 in each dc)
- hub: 16 nginx servers (8 in each dc)
- cassandra database cluster: 16 nodes (8 in each dc)
- project servers / compute machines: 27, with 19 in Seattle.
- compute machines:
- local hub servers: around 500.
- console servers: around 500, one for each local hub server
- sage servers: around 500, one for each local hub server
- iPython servers: around 50, since these run on demand only when user decideds to open an IPython notebook.
- Internal monitoring: 2 sessions running in different physical locations
- External monitoring: Uses the Google compute monitoring health check system, which sends text messages, emails, etc. when things go wrong.

## Implementation Language

SMC has dependencies that are written in C/C++, Java, Javascript,
etc.  Both the client and server parts of SMC itself are written
almost entirely in CoffeeScript, with a small amount of Python 2
code.   (Aside: At many points I tried hard to write numerous parts of
the server backend using Python, but this always failed for one
reason or another, resulting in having to throw away months of work.
Python is a great language for some problems, e.g., it was an excellent
choice for implementing SageMath; however, it is definitely not as good
as Node.js for implementing an I/O-bound single-threaded asynchronous backend server.  Sorry, but if you want to work on SMC, you must learn
CoffeeScript.)

Here are how some of the services are implemented:

- dns: up to Amazon (or whatever)
- stunnel: third-party C program
- haproxy: third-party C program
- nginx: third-party C program
- hub: CoffeeScript node.js program
- cassandra database cluster: third-party Java program
- project servers / compute machines: CoffeeScript node.js server that handles connections and decides what to do; a Python script (`bup_storage.py`) that actually carries out actions.
- compute machines:
- local hub servers: around 500.
- console servers: around 500, one for each local hub server
- sage servers: around 500, one for each local hub server
- iPython servers: around 50, since these run on demand only when user decideds to open an IPython notebook.
- Internal monitoring: 2 sessions running in different physical locations
- External monitoring: Uses the Google compute monitoring health check system, which sends text messages, emails, etc. when things go wrong.


## The Fundamental Design constraints

SMC is a designed to be used as a large distributed
multi-data center web application, with the assumption that
things will fail.  It is nothing like current
IPython or Sagenb, which are built mainly to be used
by a single-user.  This informs the design at every step.
I have broken them at various points, but never in a way
that can't be fixed later fairly easily.

> **Fundamental design constraint:** no single points of failure

Properly setup _**everything**_ is redundant in multiple distinct
data centers.    One can of course set things up with
single points of failure, e.g., one of the development VM images
has no redundancy at all.

**This constraint is currently violated** in one place I'm aware of, which is that I (William Stein) am the only person who knows how SMC works, and can fix things when human intervention is required.   _Your mission, if you choose to accept it, is to fix this!_

> **Fundamental design constraint:** everything must be event driven; no polling.

This is made much easier by websockets and the message passing code.

**This constraint is currently violated** in two places I'm aware of, which will be fixed:
 - the _notification system_ polls the database periodically to check for notifications for each connected user.  This will be replaced when we implement a mechanism for communicating between hub servers.
 - the _local hub watches for changes of files_ on the file system by calling stat every 5 seconds; instead it should use inotify.  Why not?  Because though node supports inotify, when I first implemented the local_hub to use them for this, it was very flaky. It might work fine now.


The following constraint is slightly less clear and well defined than the two above.

> **Fundamental design constraint:** linear horizontal scalability

Whenever possible, we choose designs where we can add more nodes in order to increase the number of users that we can handle, and in particular so we can scale up linearly to an arbitrary number of users.  Currently, we don't require that this scalability but instant or automatic -- it's fine if it takes a few hours to increase the number of servers, but not fine if it takes a month.  SMC grows very predictably, due to the academic calendar.  I do think that, given a day, I could make SMC handle a million simultaneous users via the current architecture; this would require increase quotas on Google Compute Engine, spinning up many new compute and web VM's, and... that's it.  It might be more expensive than it should be, due to the issue pointed above involving lack of pub/sub.

For a web application, the database is usually the main scalability constraint.  The Cassandra database scales linearly in the number of nodes, so by using it, we satisfy the above design constriant.  Many database-related problems are more difficult to solve using Cassandra than they
might be using PostgreSQL (a version of SMC in 2013 used PostgreSQL) or MySQL; however, the benefit is scalability.

**This constraint is currently violated** in backups of user projects, which are all made to a single disk on one machine at UW, which are then saved to other encrypted USB disks, some being disconnected from the internet.  This is causing real trouble with the backup machines being able to keep up with the right volume of the backups.  However, currently that is almost certainly a problem with ZFS being horrible for large volumes on HDD's, and this can be fixed by switching to ext4 for this purpose.  Also, in the long run, it may make sense to backup to Google Nearline Cloud Storage and/or Amazon Glacier, via some sort of service with completely different passwords, and no way to delete...  though I always want to have backups of user data that are not connected to the internet in any way.

The vaguest design constaint

> **Fundamental design constraint:** users are far more important than developers; if possible, cater to user needs rather than trying to change user behavior

For example, the persistent connection between SMC and client web browsers uses Websockets if possible, and otherwise falls back to several other approaches (e.g., long polling).   In contrast, IPython refuses to use anything except websockets, since they want to fix how people use the internet.  As another example, with SMC we regularly minify and combine a huge amount of HTML, etc., into a single download, so the user only has to download a few files, instead of a few hundred files.  This makes the developer workflow more painful, but the experience for users is better.  With IPython, they instead prefer to not seamlessly combine together many small files into a big one, since it makes working easier for developers.

This design constraint also impacts UI choices. Numerically, by far most users of SMC are students in courses, who are just encountering SageMath,
Python, LaTeX, etc. for the first time.  Thus toolbars that provide snippets of code, buttons to edit markdown, etc., should all be on by
default, with an advanced option to turn them off.   Also, it should be easy for users to ask for and get help, without having to jump through any hoops at all (e.g., joining a mailing list, signing up for github or stackoverflow.)  A good example of this is our `help@sagemath.com` email address, which anybody can just email without having to joint a mailing list or anything else.

**This constraint is currently violated** in several ways.  For example, file move works badly, which makes SMC painful for new users. Also,
the gitter chat room is a very bad (and I think vastly under-used) because
it requires a GitHub login.  And of course there is even a complete lack of documentation about Sage worksheets.   The terminal should have a bar with all the command bash commands and wizards to use them.  Etc.


> **Fundamental design constraint:** No vendor lock in.

Right now SMC is mostly running on Google Compute Engine, but it does not rely on any special features of GCE.

This is the design constraint I'm least confident about.   The plus is that it means we can switch to Amazon EC2 or Azure or our own hardware fairly easily.  Also, making a supported enterprise private version of SMC that we sell is **possible**.  If it turns out that private installs don't matter and we don't need to switch from GCE in the first year or two, then this can be revisited.

## Messaging API

Local hubs, global hubs, storage servers, and (web browser) clients
communicate (mostly) via JSON text messages.  (The exception is communication between a browser and a console server, which uses a binary protocol that is multiplexed into the websocket connection.)

The messages are all defined in the file `salvus/message.coffee`.

### Messaging Framework
The actual code to implement sending and receiving of messages is just
low-level code written from scratch in CoffeeScript and Python, against
the TCP and websocket libaries.   SMC doesn't make any use of a
third-party messaging framework, for sending messages between web browsers,
and between Unix processes.  It was in fact a lot of work to write/debug the current messaging implementation, though it isn't really that much
code (files: `misc_node.coffee` and `sage_server.py`).
However, that work is done, and the messaging code works perfectly
as far as I know.

Note that there is currently no mechanism for hubs to communicate with each other.  The plan has always been to implement this via a direct tcp connection, which is made on demand when communication is required, and time out after a few minutes of activity.  Alternatively, we could use a messaging queue and pub/sub framework (like zmq, rabbitmq, what Google compute engine has, etc.)

# The Client Frontend




# Console Server

# Sage Server

# IPython Notebook Server

# Local Hub

# Global Hub

## Notifications

## Proxy Server

# Project Server

## Snapshots

# Cassandra Database

# Synchronization

- The **foundation** of sync in SMC is Neil Frasier's differential synchronization algorithm.  Everything else that involves sync is built on top of that.
- Some algorithms used during sync are blocking and can be very compute intensive, so it is **critical** to never use it in any server -- such as a hub -- that must respond to requests in less than a second.
