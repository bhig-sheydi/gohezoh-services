# Customer notifications

The customer portal has a private in-app inbox for service request receipt and review, order confirmation, delivery status changes, and proof-of-delivery availability. Database triggers create these notifications in the same transaction as each underlying event and fan them out to the customer account's linked users.

The inbox reads only the signed-in user's notifications. Customers can mark their own notifications as read through a narrowly scoped database function. The existing self-read row-level security policy prevents reading other accounts' inboxes.

This phase delivers in-app notifications. Email and SMS delivery are not configured and need a provider and credentials before they can be enabled. Run `npm test` and `npm run test:db:linked` to validate the portal and database behavior.
