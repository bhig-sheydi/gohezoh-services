# Warehouse and Fulfillment

Phase 7 tracks goods owned by each customer at active Gohezoh warehouses. Staff receive products by customer SKU and warehouse/bin, capturing quantity, unit value, weight, dimensions, packaging, and handling information. Each receipt and order reservation/release is written to append-only inventory movements. Stock availability is on-hand quantity minus reserved quantity.

Customers see only their inventory and may request products from an active warehouse. Requests reserve available units so concurrent orders cannot exceed stock. Warehouse staff start picking, confirm the picked quantity for each product, and pack only when every line is complete. Operations releases a packed fulfillment order into the existing Service Request review queue. Stock remains reserved until the linked job is marked delivered; that transition consumes on-hand and reserved units. Existing pricing, order/job creation, partner assignment, delivery status, OTP, POD, and notification workflows then apply.

Customers may cancel an order while it is still submitted; warehouse/Operations/management may cancel before release. Cancellation releases reserved units and records a compensating movement. If Operations rejects the released request or the linked job is cancelled before delivery, its reservation is also released.

Database RLS scopes stock and orders to their customer, while warehouse, Operations, management, and Admin access follows their staff roles. The dedicated Warehouse role can receive and process inventory without finance settlement access. Management/Admin configure warehouse locations. See `20261002120000_add_warehouse_role.sql`, `20261002130000_warehouse_fulfillment.sql`, and `warehouse_fulfillment.test.sql`.
