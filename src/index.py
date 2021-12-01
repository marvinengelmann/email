def handler(event, context):
    return { 
        "statusCode": 200,
        "headers": {
            "Refresh": "0; url=mailto:hello@marvinengelmann.email",
        }
    }