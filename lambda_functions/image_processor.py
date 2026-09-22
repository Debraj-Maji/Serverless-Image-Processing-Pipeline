import json
import os
import urllib.parse
import boto3

stepfunctions = boto3.client("stepfunctions")
STATE_MACHINE_ARN = os.environ.get(
    "STATE_MACHINE_ARN",
    "arn:aws:states:ap-south-1:180273188724:stateMachine:project2-image-processing-workflow"
)

def lambda_handler(event, context):
    print("===== Workflow Starter =====")
    for record in event.get("Records", []):
        body = json.loads(record["body"])
        if "Records" not in body:
            continue
            
        for s3_record in body["Records"]:
            bucket = s3_record["s3"]["bucket"]["name"]
            key = urllib.parse.unquote_plus(s3_record["s3"]["object"]["key"])
            
            print(f"Starting workflow for s3://{bucket}/{key}")
            response = stepfunctions.start_execution(
                stateMachineArn=STATE_MACHINE_ARN,
                input=json.dumps({
                    "bucket": bucket,
                    "key": key,
                    "sourceBucket": bucket,
                    "sourceKey": key
                })
            )
            print("Execution ARN:", response["executionArn"])
            
    return {
        "statusCode": 200,
        "body": json.dumps("Workflow Started Successfully")
    }