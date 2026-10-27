#!/bin/bash
echo "tunnel";
# tofu -chdir=./environments/prod output -raw db_tunnel_command
aws ssm start-session --target i-032363a852f6b642f --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '{"host":["lytebuy-backend-prod.cooeisc9fwxo.us-west-2.rds.amazonaws.com"],"localPortNumber":["5433"],"portNumber":["5432"]}'