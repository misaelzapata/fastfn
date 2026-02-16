<?php

$FASTFN_HEADERS = [
    'Content-Type' => 'text/csv; charset=utf-8',
    'Content-Disposition' => 'attachment; filename="php-export.csv"',
    'Cache-Control' => 'no-store',
];
$FASTFN_STATUS = 200;

echo "id,source\n";
echo "10,php-mod-style\n";
echo "11,raw-output\n";
