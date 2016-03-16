// Copyright (c) 2016, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#ifndef PLATFORMS_STM_DISCO_DARTINO_SRC_DEVICE_MANAGER_H_
#define PLATFORMS_STM_DISCO_DARTINO_SRC_DEVICE_MANAGER_H_

#include "src/shared/platform.h"
#include "src/vm/port.h"

#include "platforms/stm/disco_dartino/src/device_manager_api.h"

namespace dartino {

// An instance of a open device that can be listened to.
class Device {
 public:
  enum Type {
    UART_DEVICE = 0,
    BUTTON_DEVICE = 1,
  };

  Device(const char* name, Type type) :
      name_(name),
      type_(type),
      port_(NULL),
      flags_(0),
      wait_mask_(0),
      initialized_(false),
      mutex_(Platform::CreateMutex()) {}

  // Sets the [flag] in [flags]. Returns true if anything changed.
  // Sends a message if there is a matching listener.
  bool SetFlags(uint32_t flag);

  // Clears the [flag] in [flags]. Returns true if anything changed.
  bool ClearFlags(uint32_t flag);

  // Clears the flags in wait_mask. Returns true if anything changed.
  bool ClearWaitFlags();

  uint32_t GetFlags();

  Mutex *GetMutex();

  // Returns true if there is a listener, and `(flags_ & wait_mask) != 0`.
  bool IsReady();

  void SetWaitMask(uint32_t wait_mask);

  Port *GetPort();

  void SetPort(Port *port);

  void SetHandle(int handle);

  int device_id() const { return device_id_; }
  void set_device_id(int device_id) { device_id_ = device_id; }

  const char* name() const { return name_; }
  Type type() const { return type_; }

 private:
  friend class DeviceManager;

  const char* name_;
  Type type_;

  int device_id_;

  // The port waiting for messages on this device.
  Port *port_;

  // The current flags for this device.
  uint32_t flags_;

  // The mask for messages on this device.
  uint32_t wait_mask_;

  bool initialized_;

  Mutex* mutex_;
};


class UartDevice: public Device {
 public:
  UartDevice(const char* name, UartDriver* driver)
      : Device(name, UART_DEVICE), driver_(driver) {}

  void Initialize() {
    driver_->Initialize(driver_);
  }

  // Read up to `count` bytes from the UART into `buffer` starting at
  // buffer. Return the number of bytes read.
  //
  // This is non-blocking, and will return 0 if no data is available.
  size_t Read(uint8_t* buffer, size_t count) {
    return driver_->Read(driver_, buffer, count);
  }

  // Write up to `count` bytes from the UART into `buffer` starting at
  // `offset`. Return the number of bytes written.
  //
  // This is non-blocking, and will return 0 if no data could be written.
  size_t Write(const uint8_t* buffer, size_t offset, size_t count) {
    return driver_->Write(driver_, buffer, offset, count);
  }

  uint32_t GetError() {
    return driver_->GetError(driver_);
  }

  static UartDevice* cast(Device* device) {
    ASSERT(device->type() == UART_DEVICE);
    return reinterpret_cast<UartDevice*>(device);
  }

 private:
  UartDriver* driver_;
};


class ButtonDevice: public Device {
 public:
  ButtonDevice(const char* name, ButtonDriver* driver)
      : Device(name, BUTTON_DEVICE), driver_(driver) {}

  void Initialize() {
    driver_->Initialize(driver_);
  }

  // Indicate that the button press has been recognized.
  void NotifyRead() {
    driver_->NotifyRead(driver_);
  }

  static ButtonDevice* cast(Device* device) {
    ASSERT(device->type() == BUTTON_DEVICE);
    return reinterpret_cast<ButtonDevice*>(device);
  }

 private:
  ButtonDriver* driver_;
};


class DeviceManager {
 public:
  static DeviceManager *GetDeviceManager();

  void DeviceSetFlags(uintptr_t device_id, uint32_t flags);
  void DeviceClearFlags(uintptr_t device_id, uint32_t flags);

  // Register a UART driver with the given device name.
  void RegisterUartDevice(const char* name, UartDriver* driver);

  // Register a button driver with the given device name.
  void RegisterButtonDevice(const char* name, ButtonDriver* driver);

  int OpenUart(const char* name);
  int OpenButton(const char* name);

  Device* GetDevice(int handle);
  UartDevice* GetUart(int handle);
  ButtonDevice* GetButton(int handle);

  osMessageQId GetMailQueue() {
    return mail_queue_;
  }

  int SendMessage(int handle);

 private:
  DeviceManager();

  Device* LookupDevice(const char* name, Device::Type type);

  Vector<Device*> devices_ = Vector<Device*>();

  osMessageQId mail_queue_;

  static DeviceManager *instance_;

  Mutex* mutex_;
};

}  // namespace dartino

#endif  // PLATFORMS_STM_DISCO_DARTINO_SRC_DEVICE_MANAGER_H_
