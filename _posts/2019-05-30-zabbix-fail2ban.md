---
layout: post
title:  "Monitoring Fail2ban actions with Zabbix"
author: "Ed Hull"
categories: zabbix fail2ban security homelab trigger
tags: fail2ban zabbix monitoring security homelab trigger alert
published: true
---
<br/>

I've spent a few days trying to solve this problem and Google was giving me zero hits. That, and the Zabbix documentation can be less than intuitive at times. I thought I'd share the love and show you how to monitor Ban / Unban events using Zabbix. Note that the following is tested to work with Zabbix 4.0, and I cannot guarantee that it will work with anything before that.
<br />

Fail2ban is a very powerful reactive defence tool. It siphons application and/or system logs, and given a criteria is met it can be told to perform an action. By default this action is to ban traffic from a traffic source using iptables. I use Fail2ban to reap bots and nasties from webservers, and I also use Zabbix as a monitoring tool for my hosts. (I recently setup an SMTP gateway which forwards email notifications from Zabbix to Slack - code which [can be found here](https://github.com/edhull/slacker)). The driver behind fixing this problem was that I wanted more visibility when a reactive Fail2ban step is taken. Zabbix to the rescue!

<br />

**The Item**

Create a new template (or append the following steps to an existing one).

Inside that template, create a new item with a Key of

`log[/var/log/fail2ban.log,".* (Ban|Unban) ((?:[0-9]{1,3}\.){3}[0-9]{1,3})$",,,skip,\1 \2]`

This item will parse the `/var/log/fail2ban.log` file for a string which containers either Ban or Unban followed by an IP address (with the event stored as the first regex group and the IP stored as the second). The item then returns a concatination (achieved by the `\1 \2` at the end of the argument) of the event and the IP which will be passed to the trigger. The item needs to be Zabbix Agent (active), and the Type should be set to Log. Also make sure that the Zabbix agent user has permission to read the log file!

![zabbix-item](/images/blog/zab_item1.png)

This item would match the following example lines
```
2019-05-30 19:24:00 fail2ban.actions        [61662]: NOTICE  [badbots] Ban 123.123.123.123
2019-05-30 19:25:00 fail2ban.actions        [61662]: NOTICE  [badbots] Unban 123.123.123.123
```
and send the following log events to the trigger(s)
```
Ban 123.123.123.123
Unban 123.123.123.123
```

<br />

**The Trigger**

Create a new Trigger and set the Name to include `Fail2ban {ITEM.VALUE}`. Zabbix interpolates this macro to become whatever the input to the trigger was - in our case, it will return the value we are sending it from the item (`Ban 123.123.123.123`).
Set the OK event generation to `Recovery Expression`. We want a recovery expression which is tied to the IP address so that Unban events only remove the alert for a specific IP.
The Problem Expression (replacing with your own Template name) should be set to

`{TEMPLATENAME:log[/var/log/fail2ban.log,".* (Ban|Unban) ((?:[0-9]{1,3}\.){3}[0-9]{1,3})$",,,skip,\1 \2].regexp(Ban)}=1`

and the Recovery Expression should be set to

`{TEMPLATENAME:log[/var/log/fail2ban.log,".* (Ban|Unban) ((?:[0-9]{1,3}\.){3}[0-9]{1,3})$",,,skip,\1 \2].regexp(Unban)}=1`

Set the PROBLEM event generation mode to Multiple so that each blocked IP generates its own event, and set `OK event closes` to `All problem if tag values match`. We want to associate an avent with a specific IP, and this is the magic which allows it to happen.

![zabbix-trigger](/images/blog/zab_trig1.png)

Set the `Tag for matching` to `IP` and create two tags; IP and ACTION. IP should have a value of `{% raw %}{{ITEM.VALUE}.regsub("^(Ban|Unban) ((?:[0-9]{1,3}\.){3}[0-9]{1,3})$", "\2")}{% endraw %}` and ACTION a value of `{% raw %}{{ITEM.VALUE}.regsub("^(Ban|Unban) ((?:[0-9]{1,3}\.){3}[0-9]{1,3})$", "\1")}{% endraw %}`. These regsub actions take the input to the trigger and split it into two key:value pairs. In our example input of `Ban 123.123.123.123`, it will result in a new alert with two tags - `IP:123.123.123.123` and `ACTION:BAN`.

The result should look like the following:
![zabbix-screen](/images/blog/zab1.png)

You may need to restart the zabbix-agent on your host to force it to query the server for new Active monitors, but viola! You should now have alerts which appear and disappear when a host is banned and unbanned.

![zabbix-dashboard](/images/blog/zab_dashboard.png)


<br />
<br />
Bonus picture - [using a custom SMTP endpoint to send Zabbix Action emails to Slack!](https://github.com/edhull/slacker)


![zabbix-slack](/images/blog/zab_slack.jpg)
