import requests

resp = requests.post(
    "https://console.vast.ai/api/v0/bundles/",
    headers={
        "Authorization": "Bearer 41d224558c794cadb15767bb3b447925eb26fb4f7c34d17e523c8aa8b583d884",
        "Content-Type": "application/json"
    },
    json={
        "limit": 20,
        "type": "ondemand",
        "order": [["dph_total", "asc"]],
        "rentable": {"eq": True},
        "rented":   {"eq": False},
        "disk_space": {"gte": 100},    # enough disk only
        "direct_port_count": {"gte": 1},  # needs open ports for our API
        "gpu_ram": {"gte": 25000}
    }
)
offers = resp.json().get("offers", [])
print(f"Found {len(offers)} offers")
for o in offers:
    print(
        o.get("id"),
        "| GPU:", o.get("gpu_name"),
        "| RAM:", o.get("gpu_ram"), "MB",
        "| $", round(o.get("dph_total",0), 4), "/hr",
        "| disk:", round(o.get("disk_space",0),1), "GB",
        "| ports:", o.get("direct_port_count")
    )