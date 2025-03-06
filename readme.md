# Useful things

## Disks
### Disk Caching
https://lonesysadmin.net/2013/12/22/better-linux-disk-caching-performance-vm-dirty_ratio/

## Graphics
### Intel Drivers
https://github.com/intel/compute-runtime

## Transcoding
https://tomthegreat.com/blog/setting-up-ubuntu-20-04-lts-for-plex-with-intel-gen-12-cpu/amp/

## Apps
### DNS ad blocking
#### Adguard (or Pihole) High Availability with Tailscale
Tailscale races DNS so by using their DNS implementation and configuring multiple DNS servers you can easily create a highly available DNS setup. 
1. Install Adguard on 2 (or more) hosts and configure
2. Install [Adguardhome-sync](https://github.com/bakito/adguardhome-sync) and configure
3. Install Tailscale on each host and configure, make sure to accept dns (`tailscale up --accept-dns`)
4. Add each Adgaurd host Tailscale IP to Tailscale DNS (through the dashboard) and ensure you toggle "Override local DNS" to On

Tailscale will now query all of the DNS servers and return whichever result comes back fastest. Adguard sync means you can set a primary server and have everything automatically updated. 

One thing I choose to do is not sync DNS rewrites and create a domain called `test.test` and enter the Tailscale URL for that host so I can easily query test.test and see which host is responding to my request. 

#### Ubuntu DNS port unable to bind error
Modern releases of Ubuntu (17.10+) and Fedora (33+) include systemd-resolved which is configured by default to implement a caching DNS stub resolver. This will prevent pi-hole from listening on port 53. 

`sudo sed -r -i.orig 's/#?DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf`

`sudo sh -c 'rm /etc/resolv.conf && ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf'`

Credit to pihole for this: https://github.com/pi-hole/docker-pi-hole/?tab=readme-ov-file#installing-on-ubuntu-or-fedora

### Monit
Monitor and respond to failures automatically: https://github.com/hucknz/useful/blob/main/monit.md

### SnapRAID
SnapRAID helper script to run each day and notify of outcomes via healthchecks.io: https://github.com/hucknz/useful/tree/main/snapraid
