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

