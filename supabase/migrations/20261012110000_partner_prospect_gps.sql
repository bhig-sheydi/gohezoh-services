alter table public.partner_prospects
  add column latitude double precision,
  add column longitude double precision,
  add column location_accuracy_metres double precision,
  add column location_captured_at timestamptz;

alter table public.partner_prospects
  add constraint partner_prospects_gps_pair_check
    check ((latitude is null and longitude is null) or
      (latitude between -90 and 90 and longitude between -180 and 180)),
  add constraint partner_prospects_gps_accuracy_check
    check (location_accuracy_metres is null or location_accuracy_metres >= 0),
  add constraint partner_prospects_gps_metadata_check
    check ((latitude is null and location_accuracy_metres is null and location_captured_at is null)
      or (latitude is not null and location_accuracy_metres is not null and location_captured_at is not null));
