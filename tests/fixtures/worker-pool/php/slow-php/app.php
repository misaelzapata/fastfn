<?php

function handler($event) {
  usleep(200000);
  return [
    "status" => 200,
    "headers" => ["Content-Type" => "application/json"],
    "body" => json_encode(["ok" => true, "runtime" => "php"]),
  ];
}

