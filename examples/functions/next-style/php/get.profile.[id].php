<?php

require_once __DIR__ . '/_shared.php';

function handler(array $event): array
{
    return next_style_json_response(next_style_profile_payload($event));
}
