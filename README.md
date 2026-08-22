# README

To build stuff, just run `make` and read the menu.

Here's my docker network setup:

```sh
jupiter $ cat /etc/docker/daemon.json 
{
    "debug": false,
    "default-address-pools": [
        {
            "base": "10.255.0.0/8",
            "size": 24
        }
    ],
    "registry-mirrors": ["https://mirror.gcr.io"],
    "ipv6": true,
    "fixed-cidr-v6": "2001:db8:1::/64"
}
```

## Useful tools

Consider installing:

* k9s - Make it easy to dig around in your cluster.
* kubens - Make it easy to change namespaces.

There's a troubleshooting image that gets installed into the cluster. Check it out!

## Cleanup stuff

Squash your entire git history to a single commit:

`git reset $(git commit-tree "HEAD^{tree}" -m "A new start")`

Clean up docker:

`docker system prune`

Nuke an entire k8s namespace:

`kubectl delete namespace app01-ns --recursive`

