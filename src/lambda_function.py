import boto3
import json
import os

from nacl.signing import VerifyKey
from nacl.exceptions import BadSignatureError

verify_key = VerifyKey(bytes.fromhex(os.getenv('discord_public_key')))

client = boto3.client('sqs', aws_access_key_id=os.getenv('sqs_access_key'), aws_secret_access_key=os.getenv('sqs_secret_key'), region_name='ap-northeast-1')
queue_url = os.getenv('sqs_queue_url')

print('Loading function')
dynamo = boto3.client('dynamodb')

def respond(status=200, res=None):
    return {
        'statusCode': status,
        'body': json.dumps(res, indent=4),
        'headers': {
            'Content-Type': 'application/json',
        },
    }


def lambda_handler(event, context):
    
    print("###### event occured!!!")
    bodystr   = event["body"]
    signature = event["headers"]["x-signature-ed25519"]
    timestamp = event["headers"]["x-signature-timestamp"]

    try:
        verify_key.verify(f'{timestamp}{bodystr}'.encode(), bytes.fromhex(signature))
    except BadSignatureError:
        return (401, 'invalid request signature')

    body = json.loads(bodystr)
    print(body)

    options = {elem['name']:elem for elem in body['data']['options']}

    if body["type"] == 1: # PING
        return respond(200, {
            "type": 1
        })
    elif body["type"] == 2: # APPLICATION_COMMAND
        response = client.send_message(QueueUrl=queue_url, MessageBody=json.dumps(body))
        print(response)
        return respond(200, {
            "type": 4,
            "data": {
                "tts": False,
                "content": f"Queue Submit! Body: {options['body']['value']} mesageID: {response['MessageId']}",
                "embeds": [],
                "allowed_mentions": { "parse": [] }
            }
        })
    elif body["type"] == 3: # MESSAGE_COMPONENT
        pass
    elif body["type"] == 4: # APPLICATION_COMMAND_AUTOCOMPLETE
        pass
    elif body["type"] == 5: # MODAL_SUBMIT
        pass

    print("===========ERROR=============")
    print(json.dumps(event, indent=4))
    return respond(503, event)

