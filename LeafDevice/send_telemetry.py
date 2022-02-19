import os
import json
import random
import asyncio
from dotenv import load_dotenv
from azure.iot.device.aio import IoTHubDeviceClient

async def main():
    # Fetch the connection string from an enviornment variable
    load_dotenv(".env")
    conn_str = os.getenv("IOTHUB_DEVICE_CONNECTION_STRING")

    # Create instance of the device client using the authentication provider
    device_client = IoTHubDeviceClient.create_from_connection_string(conn_str)

    # Connect the device client.
    await device_client.connect()

    count = 0
    # Message loop
    while True:
        print("Sending message...")
        body = {
            "count": count,
            "temperature": random.uniform(35.5, 85.5),
        }
        await device_client.send_message(json.dumps(body))
        print("Message successfully sent!")

        count += 1
        await asyncio.sleep(10)

    # await device_client.shutdown()

if __name__ == "__main__":
    asyncio.run(main())