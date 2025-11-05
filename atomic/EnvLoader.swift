//
//  EnvLoader.swift
//  atomic
//
//  Утилита для загрузки переменных окружения из .env файла

import Foundation

class EnvLoader {
    static func loadEnvFile() {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        
        // Если GEMINI_API_KEY уже установлен - не загружаем .env
        if let existingKey = env["GEMINI_API_KEY"], !existingKey.isEmpty {
            print("✅ GEMINI_API_KEY уже установлен из переменных окружения")
            return
        }
        
        // Ищем .env файл в разных местах
        var envPath: String?
        let searchPaths: [String] = {
            var paths: [String] = []
            
            // 1. Явно указанный путь
            if let customPath = env["ENV_FILE_PATH"] {
                paths.append(customPath)
            }
            
            // 2. Получаем путь к исполняемому файлу и идем вверх по дереву
            if let executablePath = Bundle.main.executablePath {
                var currentPath = (executablePath as NSString).deletingLastPathComponent
                
                // Поднимаемся на 5 уровней вверх, проверяя каждый
                for _ in 0..<5 {
                    paths.append(currentPath + "/.env")
                    currentPath = (currentPath as NSString).deletingLastPathComponent
                }
            }
            
            // 3. Текущая рабочая директория
            let currentDir = fileManager.currentDirectoryPath
            paths.append(currentDir + "/.env")
            
            // 4. На уровень выше текущей директории
            let parentDir = (currentDir as NSString).deletingLastPathComponent
            paths.append(parentDir + "/.env")
            
            return paths
        }()
        
        // Ищем первый существующий файл
        for path in searchPaths {
            if fileManager.fileExists(atPath: path) {
                envPath = path
                break
            }
        }
        
        guard let finalPath = envPath else {
            print("⚠️ Файл .env не найден. Проверенные пути:")
            for (index, path) in searchPaths.prefix(3).enumerated() {
                print("   \(index + 1). \(path)")
            }
            print("   Создайте .env файл или установите GEMINI_API_KEY в Xcode")
            return
        }
        
        print("✅ Найден .env файл: \(finalPath)")
        
        do {
            let content = try String(contentsOfFile: finalPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                // Пропускаем пустые строки и комментарии
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    
                    continue
                }
                
                // Парсим KEY=VALUE
                let parts = trimmed.components(separatedBy: "=")
                guard parts.count >= 2 else { continue }
                
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
                
                // Устанавливаем переменную окружения
                setenv(key, value, 1)
                print("✅ Загружена переменная: \(key)")
            }
        } catch {
            print("❌ Ошибка чтения .env файла: \(error)")
        }
    }
}
