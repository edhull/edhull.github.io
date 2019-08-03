---
layout: post
title:  "Proxmox and Docker"
author: "Ed Hull"
categories: portainer proxmox docker
tags: portainer proxmox docker macvlan networking iptables container virtualization   
published: true
---
<br/>
I'm an avid Proxmox advocate for homelabbing. I’ve used it for the last 5 years and I enjoy using it immensely. 

_However._

There is one thing that’s missing, and recently I’ve become more and more conscious about. **I really wish that Proxmox supported Docker integration out of the box.** Or even the ability to append a module which enabled Docker support, even if only in the GUI. Or [to not have laughable forum threads pretending LXC is the answer to Docker](https://forum.proxmox.com/threads/docker-support-in-proxmox.27474/). Or to just breathe in the general direction of Docker. 

Yeah, I get it. Proxmox is there as the interface to a hypervisor and lets you steer the ship where you want it to go. Docker is all about ephemeral containers and arguably clashes with the direction Proxmox has gone with LXC. But that doesn’t change the fact that I want to provide services, **regardless of the technology they run on under the hood.**

I run a single node Proxmox homelab for learning and funsies. The host has a single primary physical ethernet interface and multiple internal virtual bridges which separate services into their own subnets. NICs for the LXC/VMs then attach to these subnets, with iptables on the host determining which traffic to forward between interfaces and how to expose services. Some services are directly bridged to the LAN and exposed as hosts with a 192.168.x.x address, but for this guide we can ignore those for now.
<br />
<br/>
![proxmox-docker-img](/images/blog/docker_prox.png)

<br/>
This is a highly abstract view of what I was looking to create. I wanted individual Docker containers to share networking with LXC and VMs within Proxmox.
<br/>
I use a mix of VMs and LXC containers sharing networking space, and the question I recently set out to solve was whether I could transition some services from LXC to Docker whilst preserving the same networking layout. If this were Kubernetes then this would be a really bad question to ask - Kube already handles networking overlays and is definitely not designed to be running in tandem with VMs on the same nodes. The scope of my problem is only to be running vanilla Docker so this solution fits the bill. 

The answer to my question was – *yes*! Virtual machines, LXC containers, and Docker containers can all share the same virtual networking within a Proxmox node. This is possible thanks to the macvlan network driver that Docker provides. However, it takes some effort to get working (See Step 3 below)


<br/>
**Step 1 – Install Docker engine**

The first step was installing the Docker engine on my Proxmox node. I first tested this on a Proxmox 5 node to make sure it was even possible and it worked first time, but I had [a few issues getting the standard docker-ce engine to start running on my Proxmox 4 host](https://gist.github.com/dferg/58360f73b096995ec0c56530a2e65e51). 

Start by making sure your Proxmox installation is up to date

```
apt-get update && apt-get dist-upgrade -y
```

Trust and install the docker-ce binary
```
apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common
curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
apt-key fingerprint 0EBFCD88
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
apt-get update && apt-get install docker-ce -y
````
Check that ```docker ps``` returns a result.

```
CONTAINER ID        IMAGE                        COMMAND                  CREATED             STATUS              PORTS                    NAMES
```
Boom!

<br />
**Step 2 – (Optional) Stand up a container management solution**

I used Portainer because I like the interface and there are a ton of guides out there for it, but you can just as easily use any other GUI or just stick with the CLI.

```
docker run --name=portainer --restart always -d -p 80:9000 -v /var/run/docker.sock:/var/run/docker.sock -v /home/something/portainer:/data portainer/portainer
```
<br />

![portainer-img](/images/blog/portainer.jpeg)

I only use Portainer for read-only activities – all of my containers are managed through Docker Compose apart from Portainer itself (see Step 4). 

<br />
**Step 3 – Configure Host Networking**

Docker has `none`, `bridge`, and `host` networking interfaces provided out-of-the-box. By default new containers will be placed into the `bridge` network unless you specify otherwise. 
For this solution to work we need a new type of network using a `macvlan` [driver](https://docs.docker.com/network/macvlan/) . Without going into too much detail, macvlan allows you to place containers into networks that your host is already aware of, rather than keeping a container isolated within an internal Docker network. A use case of this would be taking your machine running on your LAN at `192.168.10.4/24` and creating a new nginx container accessible at `192.168.10.5/24` for all LAN users to reach without needing to expose any ports. Just what we need!

This is the part where you think to yourself “wow, things are going really smoothly, something has to go wrong soon?!” and then it does actually go wrong. 

For security reasons when using a Docker macvlan driver the container and the host are not allowed to directly communicate. [This is intentional behaviour](https://github.com/moby/moby/issues/21735). The result is that any other host on your network you can ping your new container and access it without issue, but the host running the container will be blind to it. This would make things like monitoring and debugging a bit of a nightmare. But fear not! There is a work around.

The host and the container cannot directly communicate whilst the container is using a macvlan driver – unless the host is also using a macvlan driver! For each of the vmbr* devices (excluding vmbr0) in the illustration above we need to create a new interface which uses the macvlan driver, then tell the new interface to point at the existing interface, and update all routes to use the new interface.

If this was the existing entry in your `/etc/network/interfaces` file for one of your subnets:
```
auto vmbr1
iface vmbr1 inet static
	address  10.50.0.1
	netmask  255.255.255.0
	bridge_ports none
	bridge_stp off
	bridge_fd 0
```
You want to update it into the following:
```
auto vmbr1
iface vmbr1 inet static
	address  10.50.0.1
	netmask  255.255.255.0
	bridge_ports none
	bridge_stp off
	bridge_fd 0

auto vmbr1_macvlan
iface vmbr1_ macvlan inet static
        address  10.50.0.1
        netmask  255.255.255.0
        bridge_ports none
        bridge_stp off
        bridge_fd 0
	pre-up route del -net 10.50.0.0 netmask 255.255.255.0
	pre-up ip link add vmbr1_macvlan link vmbr1 type macvlan mode bridge
```
Bring the interface up with

```
ifup vmbr1_macvlan
```

If you check your routes you should find that there is no longer a route using the vmbr1 interface – instead it has been replaced by the vmbr1_macvlan interface. 

Running `netstat –r` now returns
```
Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface
default         192.168.1.254   0.0.0.0         UG        0 0          0 vmbr0
10.50.0.0      *               255.255.255.0   U         0 0          0 vmbr1_macvlan
```
This tells traffic destined for the network we want to place our container to use the macvlan interface (`vmbr1_macvlan`) rather than the standard bridge interface (`vmbr1`). From Docker’s perspective we are not hitting the container directly so the traffic is allowed to pass unhindered. Win!

If you use interface names (eg. `vmbr1`) to construct your iptables rules be sure to update them to reflect this new macvlan interface (eg. `vmbr1_macvlan`). 

<br />
**Step 4 – Build**

I personally use Docker Compose to manage my (small scale) container deployments. 

If you go down this route then follow [these instructions to install Docker Compose on your host](https://docs.docker.com/compose/install/)

I split my docker-compose.yml files into one-per-subnet (a folder per subnet, with each folder containing a docker-compose.yml file) but this is up to you to decide.

Create a YAML similar to the following (tweak it as you see fit):
```
version: '2.1'
services:
  nginx:
    hostname: nginx-test
    image: ‘library/nginx:latest'
    restart: always
    mem_limit: 30M
    cpuset: 0,1
    ports:
      - '80'
    networks:
      test:
        ipv4_address: 10.50.0.50
networks:
  test:
    driver: macvlan
    driver_opts:
      parent: vmbr1
    ipam:
      config:
        - subnet: 10.50.0.0/24
```
This compose file will create a new macvlan-driven Docker network and attach it to your existing vmbr1 interface. It will also create an nginx Docker container and attach it to this new network. 


<br/>
**Step 5 – Deploy**

Enter the directory of your new compose file and bring it up with 

```docker-compose up -d```

(the –d detaches you from the session so you aren’t interactive) 

Running a `docker network ls` will confirm that your new network exists, and you can run a `docker inspect` on your container to verify that it is attached to the test network.


<br/>
**Step 6 - Configure Network Routing**

_Added 03/18 after a tweet from [@seffyroff](https://twitter.com/seffyroff/status/973340700841357312)_ Thanks for the feedback!

With your containers, LXC, and VMs running you may still need to configure overall networking so that they can access the outside. To do this you will need to configure your host to act as a router so that it can masquerade on behalf of the container/VM when they attempt to access external addresses (the LAN, the internet).

Tell your host that it is allowed to masquerade by updating your /etc/network/interfaces file. In my example below `vmbr1` is the interface for the VM subnet, `vmbr0` is the bridge to the LAN, and `eth0` is the physical port out to the LAN:
```
auto eth0
iface eth0 inet manual
        post-up echo 1 > /proc/sys/net/ipv4/conf/eth0/proxy_arp
auto vmbr0
iface vmbr0 inet static
        address  192.168.1.4
        netmask  255.255.255.0
        gateway  192.168.1.1
        bridge_ports eth0
        bridge_stp off
        bridge_fd 0
        bridge_maxwait 0
        post-up echo 1 > /proc/sys/net/ipv4/conf/vmbr0/proxy_arp
auto vmbr1
iface vmbr1 inet static
        address  10.50.0.1
        netmask  255.255.255.0
        bridge_ports none
        bridge_stp off
        bridge_fd 0
        post-up echo 1 > /proc/sys/net/ipv4/ip_forward
	post-up echo 1 > /proc/sys/net/ipv4/conf/vmbr0/proxy_arp
auto vmbr1_macvlan
iface vmbr1_ macvlan inet static
        address  10.50.0.1
        netmask  255.255.255.0
        bridge_ports none
        bridge_stp off
        bridge_fd 0
        pre-up route del -net 10.50.0.0 netmask 255.255.255.0
        pre-up ip link add vmbr1_macvlan link vmbr1 type macvlan mode bridge
```
Note the `post-up echo 1 > /proc/sys/net/ipv4/ip_forward` line! 

Next iptables needs to be configured to allow traffic to flow. I won't cover persisting these changes, but it's not difficult to package these rules into a script which triggers when an interface comes up.

```
# Set iptables to forward traffic between interfaces by default
# Look at locking this down if you have multiple subnets that you don't want open routing between
iptables -P FORWARD ALLOW

# Deny PING forwarding
iptables -A FORWARD -p icmp -j DROP

# Allow traffic from your VM/LXC/Docker subnets, and allow that traffic to be masqueraded to the LAN/internet
iptables -t nat -A PREROUTING -p tcp --source 10.50.0.0/24 -j ACCEPT
iptables -t nat -A PREROUTING -p udp --source 10.50.0.0/24 -j ACCEPT
iptables -t nat -A POSTROUTING -s '10.50.0.0/24' -o vmbr0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s '10.50.0.0/24' -o eth0 -j MASQUERADE

# Optionally block VMs/LXC/Docker containers from SSH'ing to the host
iptables -I INPUT -s 10.50.0.0/16 -p tcp --dport 22 -j REJECT

# An example of forwarding port 5050 on the host to port 80 on a VM/LXC/Docker container at 10.50.0.42
iptables -t nat -A PREROUTING -p tcp --dport 5050 -j DNAT --to-destination 10.50.0.42:80
```

The final step is to test curling the container from an existing virtual machine on the same subnet and also directly from the host. If all goes well you should be receiving a response for both. If you are having trouble, double check for any existing iptables rules which need to be updated to reflect the new interfaces and make sure the container ipv4_address doesn’t collide with any existing machines. 

Hopefully this is of some use!


Useful Links:

[https://www.servethehome.com/creating-the-ultimate-virtualization-and-container-setup-with-management-guis/](https://www.servethehome.com/creating-the-ultimate-virtualization-and-container-setup-with-management-guis/)

[https://forums.servethehome.com/index.php?threads/proxmox-ve-5-0-and-docker-with-a-web-gui.13902/](https://forums.servethehome.com/index.php?threads/proxmox-ve-5-0-and-docker-with-a-web-gui.13902/) (Also the inspiration behind going on this adventure, big thanks!)

