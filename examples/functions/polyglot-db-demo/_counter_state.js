let sharedMemoryCount = 0;

function readMemoryCounter() {
  return sharedMemoryCount;
}

function incrementMemoryCounter() {
  sharedMemoryCount += 1;
  return sharedMemoryCount;
}

module.exports = {
  readMemoryCounter,
  incrementMemoryCounter,
};
