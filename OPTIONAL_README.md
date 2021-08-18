# Notes about deployment workflow

- The `mongodb-node` defines the UserData which is script that runs at instance boot.
- The script runs `cfn-init` which is a cloudformation helper script. This python script reads the "AWS::CloudFormation::Init" key (see mongodb.node.template) and acts accordingly. In the case of mongodb, it is only used to create a file that contains the admin password to mongodb which is passed as a param to the CF template.
- Then it fetches the following 3 scripts from S3:
    - orchestrator.sh
    - disable-transparent-hugepages
    - init_replica.sh -> init.sh
    - signalFinalStatus.sh
- Creates `config.sh` with the following contents:
    ```
    export TABLE_NAMETAG=_mongo-db-bruno-MongoDBStack-6KKDK53KI83A
    export MongoDBVersion=4.2
    export VPC=vpc-038131b4bb406b689
    export WAITHANDLER='https://cloudformation-waitcondition-us-west-1.s3-us-west-1.amazonaws.com/arn%3Aaws%3Acloudformation%3Aus-west-1%3A501351204723%3Astack/mongo-db-bruno-MongoDBStack-6KKDK53KI83A/6bbdac40-fab1-11eb-9b1f-06bd1af66c8b/PrimaryReplicaNode0WaitForNodeInstallWaitHandle?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20210811T143554Z&X-Amz-SignedHeaders=host&X-Amz-Expires=86399&X-Amz-Credential=AKIAJNCMQWJFN7ZCAYVQ%2F20210811%2Fus-west-1%2Fs3%2Faws4_request&X-Amz-Signature=4a9fba985240d9080d5320c007a0c14e3765c6416fdd77ee32c49d92d47dd76b'
    export MONGODB_ADMIN_USER=admin
    ```
- Then it runs init.sh which configures mongoDB. It leverages dynamoDB (creating, tables, recrods) to orchestrate the creation/configuration of mongoDB. In particular, one of the uses of dynamDB is for nodes to publish their IPs so that the PrimaryNode knows which nodes to contact for joining them into the replicaSet.
- The instance get the configuration from few places:
    - the instance get its instance ID from the Identity document
    - Then it gets other information from the its tags (`aws ec2 describe-tags`):
        - stack-name
        - stack-id
        - ReplicaShardIndex
        - ClusterReplicaSetCount
        - Name
        - NodeReplicaSetIndex
- Once the setup is complete the dynamoDb tables are deleted.

# DynamoDB

In order to coordinate their progress nodes make use of DynamoDB.
First, the primary nodes of each replicaSet (config, mongo, shard0, shard1, ...) create a table per replicaset withe the name ~ s<REPLSETNAME>_MONGODB_<STACK_NAME>-<REPL_SET_NAME>-<VPC_ID> (i.e. sconfig_MONGODB__mongo-db-bruno-ConfigReplicaSet-1SRDVUXD2XXNW_vpc-053bc644903df0916)

And create an entry with the following fields

```
{
    "PrivateIpAddress: "x.x.x.x",
    "InstanceId": <INSTANCE_ID>,
    "Status": <WORKING | SECURED | FINISHED>
}
```

To wait for the secondary nodes, the primary node runs a loop of `aws dynamodb scan --table-name <TABLE_NAME>` parses the output and waits until the count becomes 3.

# How does the cluster gets secured
The way the cluster is secured is by: 
- The primary replica creates an auth key using the `orcherstrator -k` command in setup_security_common()
- It publishes this key in DynamoDB
- It creates a file named `/mongo_auth/mongodb.key` 
- It updates the `mongod.conf` configuration by adding the field `processManagement.security.keyFile`
- Restarts mongod.

- The secondary replicas fetch this key from DynamoDB

# Workflow added to create a sharded DB cluster
- Create a config server replica set

# Default Mongo Ports

27017 for mongod (if not a shard member or a config server member) or mongos instance
27018 if mongod is a shard member
27019 if mongod is a config server member

# MongoDB Topologies

There are a few different topologies that can be used to deploy MongoDB. The two big brad categories are :
- Replica Set
- Sharded

Given the expected load, it was decided to deploy a Sharded MongoDB cluster. Within a Sharded MongoDB deployment there are few alternatives regarding the deployment of the mongos.
The following website gives a good description of the different possibilities:

```
https://www.percona.com/blog/2017/11/14/common-mongodb-topologies/
```

Within the sharded deployment, there are three alternatives on how to deploy the `mongos`:
- Flat Mongos (not load balanced)
- Load Balanced
- App Centric

The main disadvantage of using a "Load Balanced" architecture is that "new drivers have issues with getMores. By this we mean the getMore selects a new random connection, and the load balancer can’t be sure which mongos should get it. Thus it has a one in N (number of mongos) chance of selecting the right one, or getting a “Cursor Not Found” error."
There is a JIRA ticket that is about warning users about not placing load balancer between the DB and the application for this very reason:

```
https://jira.mongodb.org/browse/DOCS-12322
```

The following two websites also describe similar issue:

```
https://github.com/strapi/strapi/issues/5839
```

```
https://github.com/parse-community/parse-server/issues/5226
```


The main disadvantage of using an app centric "mongos" architecture is that mongos tend to use a lot of resources.

After a discussion with John we agreed on the following points:

So after some research, I think we should avoid an ALB/NLB in front of mongos . Alternatives:
- DNS round-robin or SRV records for mongos instances
- Random mongos node selection in Monarch
- Multiple mongos URIs in the connection config string
- Run mongos in the monarch container, maybe a shell out on startup from the monarchd binary
- Don't worry about scaling mongos for now
I think any of these are viable paths forward.

# Other

- The file `/etc/sysconfig/mongod` is created by the `init_replica.sh` script.
- The `mongos.service` should go in `/usr/lib/systemd/system/`
