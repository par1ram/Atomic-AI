//
//  atomicApp.swift
//  atomic
//
//  Created by Владислав Хорунжий on 24.09.2025.
//
//  ОБРАЗОВАТЕЛЬНЫЙ КОД: Для обучения, соблюдайте законы о конфиденциальности.
//  Запрашивайте разрешения пользователя на микрофон и захват экрана.

import SwiftUI
import AppKit
import Carbon

@main
struct atomicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// Глобальный hotkey handler
class HotkeyManager {
    static let shared = HotkeyManager()
    private var sendHotkey: EventHotKeyRef?
    private var toggleHotkey: EventHotKeyRef?
    private var clearHotkey: EventHotKeyRef?
    weak var coordinator: AppCoordinator?

    func registerHotkeys() {
        print("🔑 Регистрация глобальных hotkeys...")

        // Cmd+Enter для отправки
        let sendGlyph = UInt32(kVK_Return)
        var sendHotkeyRef: EventHotKeyRef?
        let sendHotkeyID = EventHotKeyID(signature: OSType(0x4154), id: 1)

        RegisterEventHotKey(
            sendGlyph,
            UInt32(cmdKey),
            sendHotkeyID,
            GetEventDispatcherTarget(),
            0,
            &sendHotkeyRef
        )
        self.sendHotkey = sendHotkeyRef

        // Cmd+\ для скрытия/показа
        let toggleGlyph = UInt32(kVK_ANSI_Backslash)
        var toggleHotkeyRef: EventHotKeyRef?
        let toggleHotkeyID = EventHotKeyID(signature: OSType(0x4154), id: 2)

        RegisterEventHotKey(
            toggleGlyph,
            UInt32(cmdKey),
            toggleHotkeyID,
            GetEventDispatcherTarget(),
            0,
            &toggleHotkeyRef
        )
        self.toggleHotkey = toggleHotkeyRef

        // Cmd+R для очистки транскрипции
        let clearGlyph = UInt32(kVK_ANSI_R)
        var clearHotkeyRef: EventHotKeyRef?
        let clearHotkeyID = EventHotKeyID(signature: OSType(0x4154), id: 3)

        RegisterEventHotKey(
            clearGlyph,
            UInt32(cmdKey),
            clearHotkeyID,
            GetEventDispatcherTarget(),
            0,
            &clearHotkeyRef
        )
        self.clearHotkey = clearHotkeyRef

        // Обработчик событий
        var eventHandler: EventHandlerRef?
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                var hotkeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )

                Task { @MainActor in
                    let manager = HotkeyManager.shared
                    if hotkeyID.id == 1 {
                        print("⌨️ Глобальный Cmd+Enter нажат!")
                        await manager.coordinator?.sendRequest()
                    } else if hotkeyID.id == 2 {
                        print("⌨️ Глобальный Cmd+\\ нажат!")
                        manager.coordinator?.toggleOverlay()
                    } else if hotkeyID.id == 3 {
                        print("⌨️ Глобальный Cmd+R нажат!")
                        manager.coordinator?.clearTranscript()
                    }
                }

                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )

        print("✅ Hotkeys зарегистрированы (⌘↩ ⌘\\ ⌘R)")
    }

    deinit {
        if let sendHotkey = sendHotkey {
            UnregisterEventHotKey(sendHotkey)
        }
        if let toggleHotkey = toggleHotkey {
            UnregisterEventHotKey(toggleHotkey)
        }
        if let clearHotkey = clearHotkey {
            UnregisterEventHotKey(clearHotkey)
        }
    }
}

// AppDelegate для menu bar приложения
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("📱 Приложение запущено")
        
        // Загрузить переменные окружения из .env файла
        EnvLoader.loadEnvFile()

        // Скрыть иконку из Dock
        NSApp.setActivationPolicy(.accessory)

        // Создать menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "atom", accessibilityDescription: "Atomic AI")
            button.action = #selector(toggleMenu)
            button.target = self
            print("✅ Menu bar кнопка создана")
        }

        // Инициализировать координатор
        coordinator = AppCoordinator()
        print("✅ Координатор создан")

        // Регистрация глобальных hotkeys
        HotkeyManager.shared.coordinator = coordinator
        HotkeyManager.shared.registerHotkeys()
    }

    @objc private func toggleMenu() {
        guard statusItem?.button != nil else { return }

        let menu = NSMenu()

        if coordinator?.isRunning ?? false {
            menu.addItem(NSMenuItem(title: "Остановить", action: #selector(stopCapture), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Запустить", action: #selector(startCapture), keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func startCapture() {
        print("▶️ Нажата кнопка Запустить")
        Task { @MainActor in
            await coordinator?.start()
        }
    }

    @objc private func stopCapture() {
        coordinator?.stop()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

