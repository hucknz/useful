# Allow pihole to bind to any IP

1. Disable systemd-resolved with `sudo systemctl disable systemd-resolved.service`
2. Stop systemd-resolved with `sudo systemctl stop systemd-resolved`

Now you have port 53 open, but no dns configured for your host. To fix that, you need to edit '/etc/resolv.conf' and add the dns address. 

`sudo nano /etc/resolv.conf`

nameserver 192.168.1.9

If you have another nameserver in that file, I would comment it out to prevent issues.

Once pihole docker container gets running, you can change the dns server of your host to localhost, as you are binding port 53 to the host machine. Change again '/etc/resolv.conf' like this

`nameserver 127.0.0.1`
