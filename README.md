# Auto Tag

[![Build Status](https://img.shields.io/travis/GorillaStack/auto-tag/master.svg?style=for-the-badge)](https://travis-ci.org/GorillaStack/auto-tag)
[![Software License](https://img.shields.io/github/license/gorillastack/auto-tag.svg?style=for-the-badge)](/LICENSE.md)
![GitHub last commit](https://img.shields.io/github/last-commit/gorillastack/auto-tag.svg?style=for-the-badge)
[![Powered By: GorillaStack](https://img.shields.io/badge/powered%20by-GorillaStack-green.svg?style=for-the-badge)](https://www.gorillastack.com)

This is an open-source tagging solution for AWS. Deploy AutoTag to Lambda using CloudTrail consumed through CloudWatch Events and have each of your resources tagged with the ARN of who created it. Optionally, resources can be tagged with when it was created and which AWS service invoked the request if one is provided.  It was written by [GorillaStack](http://www.gorillastack.com/).

[Read a blog post about the project](http://blog.gorillastack.com/gorillastack-presents-auto-tag).

Also see [retro-tag](https://github.com/GorillaStack/retro-tag) for a solution to retrospectively tagging your resources using CloudTrail data.

## About

Automatically tagging resources can greatly improve the ease of cost allocation and governance.

CloudWatch events delivers a near real-time stream of CloudTrail events as soon as a [supported resource type](#supported-resource-types) is created. CloudWatch event rules triggers our AutoTag code to tag the resource. In this configuration the Lambda function is executed once each time it is triggered by the CloudWatch Event Rule (one event at a time). The CloudWatch Event Rule includes a pattern filter so it is only triggered by the supported events, meaning fewer Lambda invocations and lower operational costs.

## Installation

The infrastructure consists of:

* S3 Bucket
* Main CloudFormation Stack (1 AWS region)
  * Lambda Function
  * IAM Role
* Collector CloudFormation Stack (All active AWS regions)
  * CloudWatch Events Rule
  * SNS Topic

## Custom Tags

Add pre-defined static tagging or custom tagging from the CloudTrail event. Using a JSON document, define one or more tags with either a hard-coded value or a value extracted from the CloudTrail event using variable substitution. Hard-coded tags will be applied to all [supported AWS resources](#supported-resource-types). When using variable substitution more than one variable can be provided in a single tag value, and if all of the substitutions in the field fail to be resolved the tag will not be written. That will allow for custom tags to be created using certain CloudTrail event fields that may not exist in all CloudTrail event types. Check out the [CloudTrail Log Event Reference](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-event-reference.html) for the most common fields. Also, each AWS resource will have unique fields in the `requestParameters` and `responseElements` fields that can be used. Examples of specific AWS resource CloudTrail events can be found at [CloudTrail Log File Examples](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-examples.html) or by searching in the CloudTrail event history.

Example:

```json
{
  "AutoTag_ManagedBy": "Site Reliability Engineering",
  "AutoTag_UserIdentityType": "$event.userIdentity.type",
  "AutoTag_UserName": "$event.userIdentity.userName",
  "AutoTag_ClientInfo": "SourceIP: $event.sourceIPAddress - UserAgent: $event.userAgent",
  "AutoTag_Ec2_ImageId": "$event.responseElements.instancesSet.items.0.imageId"
}
```

## Prerequisites

You will need at least 1 AWS Account, and CloudTrail should be enabled.

## Deployment Methods

We have documented two different ways to deploy the infrastructure to an AWS account. Since there are CloudFormation stacks that need to be deployed in multiple regions we've provided a script that uses the AWS CLI to deploy everything for you. The other deployment method uses CloudFormation StackSets to deploy across multiple regions.

### Script Deployment Method: Deploy through our script

This deploy script `deploy_autotag.sh` will create, delete, or update all of the AutoTag infrastructure for a single AWS account.

The script will attempt to auto-install its own dependencies: `aws-cli`, `jq`, `npm`, `git`, `zip`

The `create` command will start by creating a dedicated AutoTag S3 Bucket for storing code deployment packages in your AWS account. Then it will download or build the code package, and create both the main CloudFormation stack and the collector CloudFormation stacks. When executing the `delete` command all resources will be removed except the S3 bucket. Use the `update-release` command to update existing CloudFormation stacks to a specific release, `update-master` to update to the master branch (build required), or `update-local` to update to the local cloned git repo (build required).

#### Credentials

The deploy script can use all of the credential providers that the AWS CLI allows, see [Configure AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html) and take a look at the [deployment examples](#deployment-examples). A separate set of CLI credentials can be provided by the argument `--s3-profile` for utilizing a single S3 bucket when deploying infrastructure across multiple AWS accounts. The script will also secure the S3 bucket by blocking all public access configuration, and add the required S3 bucket-policy statement to allow the cross-account `GetObject` access if necessary. 

#### IAM Policy Permissions

The script needs at minimum the IAM permissions described in this policy: [deploy\_iam\_policy.json](deploy_iam_policy.json)

Before using this IAM policy replace the 2 occurrences of `my-autotag-bucket` with the name of your actual AutoTag S3 bucket.

#### Commands and Options

```text
Usage: deploy_autotag.sh [options] <command>

Commands:
    create                    Create the AutoTag infrastructure
    delete                    Delete the AutoTag infrastructure
    update-release            Update the AutoTag infrastructure with a specific release version
    update-master             Update the AutoTag infrastructure with the latest from the master branch
    update-local              Update the AutoTag infrastructure with the local source code

Options:
    -h   --help                  Show this screen
    -r   --region                The primary AWS region where the main CloudFormation stack will be deployed
    -p   --profile               The main AWS credential profile
    -s3bu --s3-bucket            The S3 bucket where the code package will be uploaded
    -s3pr --s3-profile           A separate AWS credential profile to upload code packages to the S3 Bucket
    -rv   --release-version      The release version to deploy, e.g. '0.5.2' or 'latest'
    -cr   --collector-regions    Regions where the collector CloudFormation stack will be deployed (space separated)
    
    -lr   --log-retention-days   The number of days to retain the Lambda Function's logs (default: 90)
    -ld   --log-level-debug      Enable the debug logging for the Lambda Function
    -dct  --disable-create-time  Disable the 'CreateTime' tagging for all AWS resources
    -dib  --disable-invoked-by   Disable the 'InvokedBy' tagging for all AWS resources
    -ct   --custom-tags          Define custom tags in a JSON document
```

#### Preparation

Follow these steps to prepare to run the `create` command.

1. Select a primary AWS `--region` for the S3 bucket and the Main CloudFormation stack
2. Pick a dedicated AutoTag `--s3-bucket` name, e.g. 'acme-autotag'
3. Configure AWS credentials for the AWS CLI, see [Configure AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html)

#### Deployment Examples

Download the latest version of `deploy_autotag.sh`, or find it in the root of the repository.

```
curl -LO https://raw.githubusercontent.com/GorillaStack/auto-tag/master/deploy_autotag.sh
chmod +x deploy_autotag.sh
```

Create the infrastructure with the latest release using either the `default`, `$AWS_PROFILE`, or `instance` AWS credentials profile.

```bash
./deploy_autotag.sh --region us-west-2 --s3-bucket my-autotag-bucket --release-version latest create
```

Create the infrastructure that tags resources only in specific regions.

```bash
./deploy_autotag.sh --region us-west-2 --s3-bucket my-autotag-bucket --release-version latest --collector-regions us-west-1 us-west-2 eu-west-1 create
```

Create the infrastructure with the latest release using a named AWS credentials profile.

```bash
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket --release-version latest --profile dev-acct create
```

Create the infrastructure using `$AWS_ACCESS_KEY_ID` and `$AWS_SECRET_ACCESS_KEY`.

```bash
export AWS_ACCESS_KEY_ID=XXX
export AWS_SECRET_ACCESS_KEY=YYY
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket create
```

Create the infrastructure using a named AWS credentials profile (`--profile`), but with the S3 Bucket operations utilizing a separate AWS credential profile (`--s3-profile`). Use this feature to deploy across multiple accounts using a single S3 bucket.

```bash
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket --profile dev-acct --s3-profile s3-acct create
```

Create the infrastructure with an additional custom tag with a static value, this tag will be applied globally across all of the [supported AWS resources](#supported-resource-types).

```bash
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket create \
--custom-tags '{"AutoTag_ManagedBy": "Site Reliability Engineering"}'
```

Create the infrastructure with an additional event-based custom tag, any key in the CloudTrail event is valid to use and it will be applied globally across all of the [supported AWS resources](#supported-resource-types) unless the field does not exist in the CloudTrail event.

```bash
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket create \
--custom-tags '{"AutoTag_UserIdentityType": "$event.userIdentity.type"}'
```

Interpolation with text in the value is supported and more than one field from the event can be rendered in a single tag value.

```bash
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket create \
--custom-tags '{"AutoTag_ClientInfo": "SourceIP: $event.sourceIPAddress - UserAgent: $event.userAgent"}'
```

Update the infrastructure to the bleeding edge (master).

```bash
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket update-master
```

Update the infrastructure to the latest git release.

```bash
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket --release-version latest update-release
```

Update the infrastructure to a specific git release - *only works for releases >= 0.5.1*.

```bash
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket --release-version 0.5.2 update-release
```

Update the infrastructure to the local git folder's current state.

```bash
git clone https://github.com/GorillaStack/auto-tag.git
cd auto-tag
./deploy_autotag.sh -r us-west-2 -s3bu my-autotag-bucket update-local
```

Delete the infrastructure.

```bash
./deploy_autotag.sh -r us-west-2 delete
```

### StackSet Deployment Method: Deploy using CloudFormation StackSets

[CloudFormation StackSet Deployment Method](STACKSET.md)

## Supported Resource Types

Currently Auto-Tag, supports the following AWS resource types:

__Tags Applied__: C=Creator, T=Create Time, I=Invoked By

|Technology                 |Event Name            |Tags Applied|IAM Deny Tag Support
|---------------------------|----------------------|------------|---
|AutoScaling Group          |CreateAutoScalingGroup|C, T, I     |Yes
|ASG Instances w/ENI & Vol  |RunInstances          |C, T, I     |Yes
|Data Pipeline              |CreatePipeline        |C, T, I     |No
|DynamoDB Table             |CreateTable           |C, T, I     |No
|CloudWatch Alarm ?         |PutMetricAlarm        |C, T, I     |?
|CloudWatch Events Rule ?   |PutRule               |C, T, I     |?
|CloudWatch Log Group ?     |CreateLogGroup        |C, T, I     |?
|EBS Volume                 |CreateVolume          |C, T, I     |Yes
|EC2 AMI w/Snapshot \*      |CreateImage           |C, T, I     |Yes
|EC2 AMI w/Snapshot \*      |CopyImage             |C, T, I     |Yes
|EC2 AMI \*                 |RegisterImage         |C, T, I     |Yes
|EC2 Customer Gateway ?     |CreateCustomerGateway |C, T, I     |?
|EC2 DHCP Options ?         |CreateDhcpOptions     |C, T, I     |?
|EC2 Elastic IP             |AllocateAddress       |C, T, I     |Yes
|EC2 ENI                    |CreateNetworkInterface|C, T, I     |Yes
|EC2 Instance w/ENI & Volume|RunInstances          |C, T, I     |Yes
|EC2 / VPC Security Group   |CreateSecurityGroup   |C, T, I     |Yes
|EC2 Snapshot \*            |CreateSnapshot        |C, T, I     |Yes
|EC2 Snapshot \*            |CopySnapshot          |C, T, I     |Yes
|EC2 Snapshot \*            |ImportSnapshot        |C, T, I     |Yes
|Elastic LB (v1 & v2)       |CreateLoadBalancer    |C, T, I     |No
|EMR Cluster                |RunJobFlow            |C, T, I     |No
|IAM Role                   |CreateRole            |C, T, I     |?
|IAM User                   |CreateUser            |C, T, I     |?
|Lambda Function ?          |CreateFunction20150331|C, T, I     |?
|Lambda Function ?          |CreateFunction20141111|C, T, I     |?
|OpsWorks Stack             |CreateStack           |C           |No
|OpsWorks Clone Stack *     |CloneStack            |C           |No
|OpsWorks Instances w/ENI & Vol|RunInstances       |C, T, I     |Yes
|RDS Instance               |CreateDBInstance      |C, T, I     |No
|S3 Bucket                  |CreateBucket          |C, T, I     |No
|NAT Gateway                |CreateNatGateway      |C, T, I     |Yes
|VPC                        |CreateVpc             |C, T, I     |Yes
|VPC Internet Gateway       |CreateInternetGateway |C, T, I     |Yes
|VPC Network ACL            |CreateNetworkAcl      |C, T, I     |Yes
|VPC Peering Connection     |CreateVpcPeeringConnection|C, T, I |Yes
|VPC Route Table            |CreateRouteTable      |C, T, I     |Yes
|VPC Subnet                 |CreateSubnet          |C, T, I     |Yes
|VPN Connection             |CreateVpnConnection   |C, T, I     |Yes
|VPN Gateway ?              |CreateVpnGateway      |C, T, I     |?

_*=not tested by the test suite_

NOTE: When tag-able resources are created using CloudFormation __StackSets__ the "Creator" tag is NEVER populated with the ARN of the user who executed the StackSet, instead it is tagged with the less useful CloudFormation StackSet Execution Role's "assumed-role" ARN. 

## Deny Create/Delete/Edit for AutoTags

Use the following IAM policy to deny a user or role the ability to create, delete, and edit any tag starting with 'AutoTag\_'. The `ec2:CreateAction` condition allows users to create EC2 instances with tags starting with 'AutoTag_', this enables the 'Launch More Like This' feature, in that case the tags will be overwritten after the instance is created.

```json
{
    "Sid": "DenyAutoTagPrefix",
    "Effect": "Deny",
    "Action": [
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "autoscaling:CreateOrUpdateTags",
        "autoscaling:DeleteTags"
    ],
    "Condition": {
        "ForAnyValue:StringLike": {
            "aws:TagKeys": "AutoTag_*"
        },
        "StringNotEquals": {
            "ec2:CreateAction": [
                "RunInstances"
            ]
        }
    },
    "Resource": "*"
}
```

NOTE: At the time of this writing the deny tag IAM condition (aws:TagKeys) is only available for resources in EC2 and AutoScaling, see the table above for a status of each resource.

## Contributing

If you have questions, feature requests or bugs to report, please do so on [the issues section of our github repository](https://github.com/GorillaStack/auto-tag/issues).

If you are interested in contributing, please get started by forking our GitHub repository and submit pull-requests.
