import json
import os
import uuid
import boto3
from botocore.config import Config

my_config = Config(
    region_name="ap-south-1",
    signature_version="s3v4",
    s3={'addressing_style': 'virtual'}
)

s3 = boto3.client("s3", region_name="ap-south-1", config=my_config)
BUCKET_NAME = os.environ.get("SOURCE_BUCKET", "project2-source-image-bucket")

CONTENT_TYPES = {
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "webp": "image/webp"
}

def lambda_handler(event, context):
    cors_headers = {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET,OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type"
    }

    try:
        params = event.get("queryStringParameters") or {}
        filename = params.get("filename")
        
        if not filename:
            filename = f"{uuid.uuid4()}.png"

        ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else "png"
        content_type = CONTENT_TYPES.get(ext, "image/png")

        upload_url = s3.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": BUCKET_NAME,
                "Key": filename,
                "ContentType": content_type
            },
            ExpiresIn=300
        )

        return {
            "statusCode": 200,
            "headers": cors_headers,
            "body": json.dumps({
                "bucket": BUCKET_NAME,
                "key": filename,
                "uploadUrl": upload_url
            })
        }
    except Exception as e:
        return {
            "statusCode": 500,
            "headers": cors_headers,
            "body": json.dumps({"error": str(e)})
        }