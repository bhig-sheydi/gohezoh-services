-- A parcel received at Gohezoh's Port Harcourt hub has not been delivered to its recipient.
alter type public.job_state add value if not exists 'hub_received';
