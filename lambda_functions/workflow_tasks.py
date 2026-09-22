from datetime import datetime, timezone
from io import BytesIO
import os
import boto3
from PIL import Image, ImageDraw, ImageFont

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")

DESTINATION_BUCKET = os.environ.get("DESTINATION_BUCKET", "project2-processed-image-bucket")
TABLE_NAME = os.environ.get("TABLE_NAME", "project2-image-metadata")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}

# 1. VALIDATE HANDLER

def validate_handler(event, context):
    bucket = event["bucket"]
    key = event["key"]

    response = s3.get_object(Bucket=bucket, Key=key)
    raw_data = response["Body"].read()

    with Image.open(BytesIO(raw_data)) as img:
        img.verify()

    with Image.open(BytesIO(raw_data)) as img:
        width, height = img.size
        img_format = img.format

    if img_format not in ALLOWED_FORMATS:
        raise ValueError(f"Unsupported format: {img_format}. Allowed: {ALLOWED_FORMATS}")

    return {
        "bucket": bucket,
        "key": key,
        "sourceBucket": event.get("sourceBucket", bucket),
        "sourceKey": event.get("sourceKey", key),
        "originalWidth": width,
        "originalHeight": height,
        "format": img_format
    }

# 2. RESIZE HANDLER

def resize_handler(event, context):
    bucket = event["bucket"]
    key = event["key"]
    img_format = event.get("format", "PNG")

    response = s3.get_object(Bucket=bucket, Key=key)
    image = Image.open(BytesIO(response["Body"].read()))

    image.thumbnail((800, 800))
    resized_width, resized_height = image.size

    if img_format.upper() in ["JPEG", "JPG"] and image.mode in ("RGBA", "P"):
        image = image.convert("RGB")

    buffer = BytesIO()
    image.save(buffer, format=img_format)
    buffer.seek(0)

    clean_key = key.replace("temp/", "")
    temp_key = f"temp/{clean_key}"

    s3.put_object(
        Bucket=DESTINATION_BUCKET,
        Key=temp_key,
        Body=buffer.getvalue(),
        ContentType=f"image/{img_format.lower()}"
    )

    return {
        "bucket": DESTINATION_BUCKET,
        "key": temp_key,
        "sourceBucket": event.get("sourceBucket"),
        "sourceKey": event.get("sourceKey", clean_key),
        "originalWidth": event["originalWidth"],
        "originalHeight": event["originalHeight"],
        "resizedWidth": resized_width,
        "resizedHeight": resized_height,
        "format": img_format
    }

# 3. WATERMARK HANDLER

def watermark_handler(event, context):
    bucket = event["bucket"]
    key = event["key"]
    img_format = event.get("format", "PNG")

    response = s3.get_object(Bucket=bucket, Key=key)
    image = Image.open(BytesIO(response["Body"].read()))

    if image.mode not in ("RGB", "RGBA"):
        image = image.convert("RGBA" if img_format.upper() == "PNG" else "RGB")

    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default()
    watermark_text = "Project 2"

    left, top, right, bottom = draw.textbbox((0, 0), watermark_text, font=font)
    text_w, text_h = right - left, bottom - top

    x = max(10, image.width - text_w - 15)
    y = max(10, image.height - text_h - 15)

    draw.text((x + 1, y + 1), watermark_text, fill="black", font=font)
    draw.text((x, y), watermark_text, fill="white", font=font)

    buffer = BytesIO()
    image.save(buffer, format=img_format)
    buffer.seek(0)

    clean_key = key.replace("temp/", "")
    processed_key = f"processed/{clean_key}"

    s3.put_object(
        Bucket=DESTINATION_BUCKET,
        Key=processed_key,
        Body=buffer.getvalue(),
        ContentType=f"image/{img_format.lower()}"
    )

    return {
        "bucket": DESTINATION_BUCKET,
        "key": processed_key,
        "sourceBucket": event.get("sourceBucket"),
        "sourceKey": event.get("sourceKey"),
        "originalWidth": event["originalWidth"],
        "originalHeight": event["originalHeight"],
        "resizedWidth": event["resizedWidth"],
        "resizedHeight": event["resizedHeight"],
        "format": img_format
    }

# 4. STORE HANDLER

def store_handler(event, context):
    bucket = event["bucket"]
    processed_key = event["key"]
    source_bucket = event.get("sourceBucket", "project2-source-image-bucket")

    # Record in DynamoDB
    table = dynamodb.Table(TABLE_NAME)
    table.put_item(
        Item={
            "ImageName": processed_key.replace("processed/", ""),
            "UploadTime": datetime.now(timezone.utc).isoformat(),
            "SourceBucket": source_bucket,
            "DestinationBucket": bucket,
            "OriginalWidth": event["originalWidth"],
            "OriginalHeight": event["originalHeight"],
            "ResizedWidth": event["resizedWidth"],
            "ResizedHeight": event["resizedHeight"],
            "Format": event.get("format", "UNKNOWN"),
            "Status": "Processed"
        }
    )

    # Publish to SNS
    if SNS_TOPIC_ARN:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Image Processing Successful",
            Message=f"Processed: {processed_key}\nBucket: {bucket}"
        )

    # Clean intermediate temp file
    temp_key = processed_key.replace("processed/", "temp/")
    try:
        s3.delete_object(Bucket=bucket, Key=temp_key)
    except Exception:
        pass

    return {"bucket": bucket, "key": processed_key, "status": "SUCCESS"}