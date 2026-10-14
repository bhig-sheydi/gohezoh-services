# Customer saved parcels

Saved parcels are available to standalone customer accounts only. The customer home shows Parcel Pals first, then **Items to send**, followed by launch cards for **Send items**, **Updates**, and **Tracking**. Each destination opens a focused customer view.

Customers can save an item name, photo, description, declared worth, price paid, length, width, height, and weight. Choosing **Use item** opens the delivery request and pre-fills parcel description, weight, dimensions, declared worth, and price paid. Pickup, recipient, address, service, quantity, and timing remain specific to each shipment.

## Pilot parcel envelope

- Per destination, customers select 1–50 matching items.
- Packed shipment length: at most 99 cm
- Packed shipment width: at most 60 cm
- Packed shipment height: at most 70.5 cm
- Packed shipment weight: at most 9.9 kg
- Photo: JPEG, PNG, or WebP, up to 5 MB

The packed shipment limits are exactly three times the researched Indomie-carton envelope of 33 × 20 × 23.5 cm and 3.3 kg. Quantity is the number of matching items going to one destination; each item's dimensions and weight are combined into a shipment estimate. The estimate multiplies item weight by quantity and checks whether identical items fit in a regular grid inside the shipment limits, allowing item rotation. The form warns immediately when the selected quantity exceeds estimated capacity, and the database rejects over-cap requests. These are pilot input limits, not carrier-specific acceptance or dangerous-goods rules. Revisit them when partner capacity tiers are configured.

## Access and data

- Saved-parcel rows are protected by row-level security and are visible only to their owning standalone customer account.
- Images are stored in a private Storage bucket and signed for display to the owner.
- Database checks enforce the size and weight envelope even if a client bypasses the form.
- Request parcel details carry through to job parcels. `declared_value` remains separate from `item_price`; neither is a delivery charge or a profit calculation.

Reference specifications: [Indomie 40 × 70 g carton](https://heuschenschroufforder.com/product/13118/inst.-noodles-chicken-indomie-pk-70g) and [ASUS Vivobook Pro 15 dimensions](https://www.asus.com/me-en/event/productguide/2025/asus-product-guide_202509.pdf).
