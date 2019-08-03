---
layout: post
title:  "Terraform in Production; Boots on the ground"
author: "Ed Hull"
published: false
---
_And now, I am become death, the destroyer of <strike>worlds</strike> statefiles_

What is this post about, and who is it aimed at. Not a terraform 101 - it's not a guide, it's an inhouse snapshot about how Terraform is being used by my current client and lessons to be learnt. F
or anyone that's read "Scrum from the Trenches" it takes the same approach, it's not a how to nor
a don't do, it's a "this is what works for us".

My current client is lucky enough to have a huge palet of new technoloies at their footstep. I won't cover use of Kubernetes or clusters in the scope of this post, it's too big to cover all at once but there's good scope to cover it in a future blog post.

For anyone reading who has never had the chance to use Terraform or AWS before, I've stuck a term glossary at the bottom of the page which can be used as reference. AWS can be a steep learning cur
ve.

What is terraform, what other technologies do we use (hashicorp stack), vs cloudformation. Basic l
ayout of terraform and how it is structured.

Secured using vault, using consul for service discovery and templates alongside puppet for provisioning tasks, Vault EC2 backend with short lived tokens

Recyclable patterns "I want an EC2 instance inside an ASG with a LB"

Our AMI images are currently in the process of being built via a Packer pipeline - we'll then be a
ble to take packerized-AMIs straight out of S3 and into an environment using AMI-copy


Bit at the end with AWS easy definitions
S3
AMI
ELB
EC2
RDS
LB
ASG
Hashicorp stack
