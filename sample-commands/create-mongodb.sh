#!/bin/bash
aws cloudformation create-stack --stack-name mongo-db-bruno --template-url https://mongo-db-sharded.s3.us-west-1.amazonaws.com/mongo-db-sharded/templates/mongodb.template --parameters file://./parameters/mongodb-parameters.json --capabilities CAPABILITY_IAM
