<?php

require_once __DIR__ . '/_shared.php';

$FASTFN_HEADERS = [
    'Content-Type' => 'text/csv; charset=utf-8',
    'Content-Disposition' => 'attachment; filename="php-export.csv"',
    'Cache-Control' => 'no-store',
];
$FASTFN_STATUS = 200;

echo next_style_render_csv(next_style_export_rows());
