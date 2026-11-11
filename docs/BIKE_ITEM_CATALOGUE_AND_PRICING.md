# Bike parcel catalogue and packed-space pricing

The customer chooses an item type, the number of matching units, the declared worth **per unit**, and a photo. The combined declared worth of all units in one request is capped at **₦70,000**. Weight and dimensions are no longer customer-entered. The database replaces any supplied measurements with its own catalogue estimates and rejects parcels outside the model.

## Box and safety assumptions

The platform estimates a usable **38 × 32 × 32 cm (38.9 L)** bike box. This is deliberately smaller than [Kwik's published 42 × 36 × 36 cm box](https://kwik.delivery/corporate-clients/) to leave clearance for packaging and box variations. [Kwik's FAQ](https://kwik.delivery/faq/) quotes a 25 kg maximum load. The app uses 25 kg only as an internal safety ceiling based on estimated packed weight; it does not ask customers to weigh goods or price by weight. Partners must check their actual box dimensions and load ratings before relying on this model.

The 80 item choices and their average packed dimensions and weights are seeded in [the database migration](../supabase/migrations/20261111123000_bike_item_catalogue_and_space_pricing.sql). They are **operating estimates**, not manufacturer measurements. Categories include:

| Category | Examples and sizing choices |
| --- | --- |
| Documents | Loose papers, passports/booklets, books, textbooks, folders, magazines, business cards. Loose papers use **1–500 pages per envelope**. |
| Hair and beauty | Short (up to 12 in), medium (13–20 in), and long (21–30 in) wigs; extensions, braiding hair, ornaments, bonnets, makeup, sealed shampoo. |
| Clothing and fashion | Shirts, jeans, dresses, wrappers, aso-oke, baby clothes, shoes, bags, belts, sunglasses, watches. |
| Electronics | Phones, tablets, padded small laptops, headphones, chargers, power banks, routers, game consoles, keyboards, cameras. |
| Home electronics | Small speakers, blenders, kettles, irons, hair dryers, mini fans, lamps, remotes. |
| Food | Sealed small/medium/large meals, 6/8/10-inch cakes, bread, pastries, groceries, fruit and dry food. |
| Other | Baby supplies, toys, gifts, flowers, stationery, printer paper, small non-sharp tools, small vehicle parts and household goods. |

The searchable list has two conservative “other boxed item” choices. Customers must describe and photograph the actual goods. A parcel being physically small does not make it safe or legal to carry. Prohibited or restricted contents must be handled under the platform's carriage rules; [NIPOST publishes prohibited-item guidance](https://nipost.gov.ng/prohibited-items/).

## Price calculation

The current distance-and-fuel bike price remains the starting price. The database adds:

`space surcharge = ₦50 × ceiling( max(0, packed volume in litres − 3) × ₦40 / ₦50 ) + ₦50 × ceiling(total loose-document pages / 100)`

This means the first 3 L of packed space is included in the existing fare. Space above that costs approximately **₦40 per additional litre**, rounded up in ₦50 steps. Loose papers add **₦50 per started 100 pages** for counting and handling. The number of units multiplies estimated packed volume. A long wig uses a larger catalogue package than a short wig. Food uses separate plate and cake-size entries. The displayed fare is the existing distance/fuel fare **plus** the space surcharge, and the company's existing 75% share is calculated on that final fare. Existing price snapshots are unchanged.

Examples, using a ₦2,100 distance/fuel fare:

| Shipment | Estimated packed volume | Space charge | Final fare |
| --- | ---: | ---: | ---: |
| One boxed phone | 1.92 L | ₦0 | ₦2,100 |
| Two short wigs | 9 L | ₦250 | ₦2,350 |
| One medium meal plate | 8.11 L | ₦250 | ₦2,350 |
| One 500-page document envelope | 4.22 L | ₦300 including page handling | ₦2,400 |

The price is locked per request after route calculation. Actual packaging may differ from the estimate; if it cannot fit or the description/photo is inaccurate, the rider or company should not collect it under that quote. This model needs a real-box pilot with partner measurements before relying on it for all bikes. It is for the current bike-sized catalogue; larger vehicles need their own capacity and price model.
