import CoreML
import UIKit

// MARK: - 超分模式

enum UpscaleMode: String, CaseIterable, Identifiable {
    case off = "关闭"
    case x2 = "Anime4K-A-HQ x2"
    case x4 = "Anime4K-A-HQ x4"
    case realesrganAnime4x = "RealESRGAN Anime 4x"
    var id: String { rawValue }
}

// MARK: - 超分错误

enum UpscaleError: LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(Error)
    case invalidImage
    case noResults
    case inferenceFailed(Error)
    case preprocessingFailed
    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name): return "找不到模型文件: \(name)"
        case .modelLoadFailed(let error): return "模型加载失败: \(error.localizedDescription)"
        case .invalidImage: return "无效的图片格式"
        case .noResults: return "推理无结果"
        case .inferenceFailed(let error): return "推理失败: \(error.localizedDescription)"
        case .preprocessingFailed: return "图片预处理失败"
        }
    }
}

// MARK: - Tile 信息（保留坐标）

private struct TileInfo {
    let srcX: Int      // 在原图中的 x
    let srcY: Int      // 在原图中的 y
    let srcW: Int      // 源宽度
    let srcH: Int      // 源高度
    let dstX: Int      // 在输出图中的 x
    let dstY: Int      // 在输出图中的 y
    let dstW: Int      // 输出宽度
    let dstH: Int      // 输出高度
}

// MARK: - Core ML 超分服务

final class ImageUpscaler {
    static let shared = ImageUpscaler()

    private var model2x: MLModel?
    private var model4x: MLModel?
    private var modelRealESRGANAnime4x: MLModel?
    private var model2xLoadFailed = false
    private var model4xLoadFailed = false
    private var modelRealESRGANAnime4xLoadFailed = false
    private var tileSize2x: Int = 128
    private var tileSize4x: Int = 128
    private var tileSizeRealESRGANAnime4x: Int = 256

    private init() {}

    // MARK: - 模型加载

    private func loadModel2x() throws -> MLModel {
        if let model = model2x { return model }
        if model2xLoadFailed { throw UpscaleError.modelNotFound("anime4k-2x-a-hq") }
        guard let modelURL = Bundle.main.url(forResource: "anime4k-2x-a-hq", withExtension: "mlmodelc") ??
                Bundle.main.url(forResource: "anime4k-2x-a-hq", withExtension: "mlpackage") else {
            model2xLoadFailed = true
            throw UpscaleError.modelNotFound("anime4k-2x-a-hq")
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            self.model2x = model
            detectTileSize(model: model, name: "2x")
            return model
        } catch {
            model2xLoadFailed = true
            throw UpscaleError.modelLoadFailed(error)
        }
    }

    private func loadModel4x() throws -> MLModel {
        if let model = model4x { return model }
        if model4xLoadFailed { throw UpscaleError.modelNotFound("anime4k-4x-a-hq") }
        guard let modelURL = Bundle.main.url(forResource: "anime4k-4x-a-hq", withExtension: "mlmodelc") ??
                Bundle.main.url(forResource: "anime4k-4x-a-hq", withExtension: "mlpackage") else {
            model4xLoadFailed = true
            throw UpscaleError.modelNotFound("anime4k-4x-a-hq")
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            self.model4x = model
            detectTileSize(model: model, name: "4x")
            return model
        } catch {
            model4xLoadFailed = true
            throw UpscaleError.modelLoadFailed(error)
        }
    }

    private func loadModelRealESRGANAnime4x() throws -> MLModel {
        if let model = modelRealESRGANAnime4x { return model }
        if modelRealESRGANAnime4xLoadFailed { throw UpscaleError.modelNotFound("RealESRGAN_x4plus_Anime") }

        guard let modelURL = Bundle.main.url(forResource: "RealESRGAN_x4plus_Anime", withExtension: "mlmodelc") ??
                Bundle.main.url(forResource: "RealESRGAN_x4plus_Anime", withExtension: "mlpackage") else {
            modelRealESRGANAnime4xLoadFailed = true
            throw UpscaleError.modelNotFound("RealESRGAN_x4plus_Anime")
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            self.modelRealESRGANAnime4x = model
            detectTileSize(model: model, name: "RealESRGAN Anime 4x")
            return model
        } catch {
            modelRealESRGANAnime4xLoadFailed = true
            throw UpscaleError.modelLoadFailed(error)
        }
    }

    private func detectTileSize(model: MLModel, name: String) {
        guard let inputDesc = model.modelDescription.inputDescriptionsByName.values.first,
              let constraint = inputDesc.multiArrayConstraint else { return }
        let shape = constraint.shape.map { Int(truncating: $0) }
        if shape.count == 4 {
            let detectedSize = shape[2]
            if name == "2x" { tileSize2x = detectedSize }
            else if name == "4x" { tileSize4x = detectedSize }
            else if name == "RealESRGAN Anime 4x" { tileSizeRealESRGANAnime4x = detectedSize }
        }
    }

    // MARK: - 超分推理

    func upscale(_ image: UIImage, mode: UpscaleMode, keepOriginalSize: Bool = false) throws -> UIImage {
        guard mode != .off else { return image }

        // ✅ 内存上限检查：防止大图像导致 OOM
        let maxDimension: CGFloat = 4096
        let imageWidth = image.size.width * image.scale
        let imageHeight = image.size.height * image.scale

        if imageWidth > maxDimension || imageHeight > maxDimension {
            throw UpscaleError.preprocessingFailed
        }

        let model: MLModel
        let tileSize: Int
        let scaleFactor: CGFloat
        switch mode {
        case .x2:
            model = try loadModel2x()
            tileSize = tileSize2x
            scaleFactor = 2.0
        case .x4:
            model = try loadModel4x()
            tileSize = tileSize4x
            scaleFactor = 4.0
        case .realesrganAnime4x:
            model = try loadModelRealESRGANAnime4x()
            tileSize = tileSizeRealESRGANAnime4x
            scaleFactor = 4.0
        case .off:
            return image
        }

        // ✅ RealESRGAN 模型强制使用 TensorType 输入
        let forceTensorInput = (mode == .realesrganAnime4x)

        let resultImage = try tileInference(image: image, model: model, tileSize: tileSize, scaleFactor: scaleFactor, forceTensorInput: forceTensorInput)

        // 直接返回超分结果，不缩放！
        if keepOriginalSize {
            let finalImage = resultImage.resize(to: image.size)
            return finalImage
        }

        return resultImage
    }

    // MARK: - Tile 推理核心（tilePad 上下文扩展）

    private func tileInference(image: UIImage, model: MLModel, tileSize: Int, scaleFactor: CGFloat, forceTensorInput: Bool = false) throws -> UIImage {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        let scale = Int(scaleFactor)

        // tilePad: 每个 tile 内部的上下文扩展像素数
        // 有效区域 = tileSize - 2 * tilePad = 256 - 32 = 224
        // 模型始终接收 256×256 输入，但边缘 16px 是上下文，推理后裁剪掉
        let tilePad = 16
        let effectiveSize = tileSize - 2 * tilePad  // 224
        let stride = effectiveSize

        // 步骤 1: 计算 tile 网格（基于有效区域步进）
        let tilesX = (imageWidth + stride - 1) / stride
        let tilesY = (imageHeight + stride - 1) / stride

        // 步骤 2: 创建输出 pixel buffer
        let finalWidth = imageWidth * scale
        let finalHeight = imageHeight * scale

        var finalPixels = [UInt8](repeating: 0, count: finalWidth * finalHeight * 4)

        // 获取输入输出信息
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first,
              let outputName = model.modelDescription.outputDescriptionsByName.keys.first,
              let inputDesc = model.modelDescription.inputDescriptionsByName[inputName] else {
            throw UpscaleError.preprocessingFailed
        }

        guard inputDesc.type == .multiArray || inputDesc.type == .image else {
            throw UpscaleError.preprocessingFailed
        }

        if forceTensorInput && inputDesc.type != .multiArray {
            throw UpscaleError.preprocessingFailed
        }

        // 步骤 3: 处理每个 tile
        let scaledTileSize = tileSize * scale      // 1024
        let scaledPad = tilePad * scale            // 64
        let scaledEffective = effectiveSize * scale // 896
        var failedTiles = 0

        for gridY in 0..<tilesY {
            for gridX in 0..<tilesX {

                // 3a. 有效区域在原图中的坐标
                let effX = gridX * stride
                let effY = gridY * stride
                let effW = min(effectiveSize, imageWidth - effX)
                let effH = min(effectiveSize, imageHeight - effY)

                // 3b. 带上下文扩展的提取区域（有效区域 + 四周 tilePad）
                let extractX = max(0, effX - tilePad)
                let extractY = max(0, effY - tilePad)
                let extractRight = min(imageWidth, effX + effW + tilePad)
                let extractBottom = min(imageHeight, effY + effH + tilePad)
                let extractW = extractRight - extractX
                let extractH = extractBottom - extractY

                // 3c. 裁剪原图得到带上下文的 tile
                guard let tileCGImage = cgImage.cropping(to: CGRect(x: extractX, y: extractY, width: extractW, height: extractH)) else {
                    continue
                }
                let tileUIImage = UIImage(cgImage: tileCGImage)

                // 3d. Pad 到 256×256（边缘 tile 可能不足，需要 pad）
                let paddedImage: UIImage
                if extractW != tileSize || extractH != tileSize {
                    paddedImage = tileUIImage.padToSize(targetSize: CGSize(width: tileSize, height: tileSize))
                } else {
                    paddedImage = tileUIImage
                }

                // 3e. 创建输入
                let inputFeature: MLFeatureProvider
                if inputDesc.type == .multiArray, let constraint = inputDesc.multiArrayConstraint {
                    let multiArray = try paddedImage.toMLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
                    inputFeature = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: multiArray)])
                } else if inputDesc.type == .image && !forceTensorInput {
                    guard let pixelBuffer = paddedImage.toPixelBuffer(width: tileSize, height: tileSize) else { continue }
                    inputFeature = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
                } else {
                    if forceTensorInput { throw UpscaleError.preprocessingFailed }
                    continue
                }

                // 3f. 推理
                let output: MLFeatureProvider
                do {
                    output = try model.prediction(from: inputFeature)
                } catch {
                    failedTiles += 1
                    continue
                }

                // 3g. 获取输出，裁剪掉上下文扩展区域，写入有效区域
                if let outputValue = output.featureValue(for: outputName) {
                    let outputTile: UIImage?
                    if outputValue.type == .multiArray, let multiArray = outputValue.multiArrayValue {
                        do {
                            outputTile = try UIImage.image(from: multiArray)
                        } catch {
                            failedTiles += 1
                            continue
                        }
                    } else if outputValue.type == .image, let pixelBuffer = outputValue.imageBufferValue {
                        outputTile = UIImage(pixelBuffer: pixelBuffer)
                    } else {
                        failedTiles += 1
                        outputTile = nil
                    }

                    if let outputTile = outputTile, let outputCGImage = outputTile.cgImage {
                        // 读取输出像素
                        let outW = outputCGImage.width
                        let outH = outputCGImage.height
                        var rawData = [UInt8](repeating: 0, count: outW * outH * 4)

                        guard let ctx = CGContext(
                            data: &rawData,
                            width: outW,
                            height: outH,
                            bitsPerComponent: 8,
                            bytesPerRow: outW * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                        ) else { continue }
                        ctx.draw(outputCGImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))

                        // 裁剪：跳过输出中对应上下文扩展的部分，只保留有效区域
                        // 上下文在输入中占 tilePad，输出中占 tilePad * scale
                        let cropX = (extractX > effX - tilePad) ? 0 : scaledPad  // 左侧是否有完整 pad
                        let cropY = (extractY > effY - tilePad) ? 0 : scaledPad  // 上方是否有完整 pad

                        // 实际输出的有效区域尺寸
                        let actualEffW = effW * scale
                        let actualEffH = effH * scale

                        // 目标位置
                        let dstX = effX * scale
                        let dstY = effY * scale

                        // 写入有效区域像素
                        for y in 0..<actualEffH {
                            for x in 0..<actualEffW {
                                let srcX = cropX + x
                                let srcY = cropY + y
                                guard srcX < outW && srcY < outH else { continue }

                                let canvasX = dstX + x
                                let canvasY = dstY + y
                                guard canvasX >= 0 && canvasX < finalWidth && canvasY >= 0 && canvasY < finalHeight else { continue }

                                let srcIdx = (srcY * outW + srcX) * 4
                                let dstIdx = (canvasY * finalWidth + canvasX) * 4
                                finalPixels[dstIdx] = rawData[srcIdx]
                                finalPixels[dstIdx + 1] = rawData[srcIdx + 1]
                                finalPixels[dstIdx + 2] = rawData[srcIdx + 2]
                                finalPixels[dstIdx + 3] = 255
                            }
                        }
                    }
                }
            }
        }

        // ✅ 检查是否有太多 tile 失败
        let totalTiles = tilesX * tilesY
        if failedTiles == totalTiles {
            throw UpscaleError.inferenceFailed(NSError(domain: "ImageUpscaler", code: -1, userInfo: [NSLocalizedDescriptionKey: "All tiles failed inference"]))
        }

        // 步骤 4: 生成最终图像
        guard let finalCGImage = finalPixels.withUnsafeMutableBytes({ buffer -> CGImage? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return CGContext(
                data: baseAddress,
                width: finalWidth,
                height: finalHeight,
                bitsPerComponent: 8,
                bytesPerRow: finalWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )?.makeImage()
        }) else {
            throw UpscaleError.preprocessingFailed
        }

        return UIImage(cgImage: finalCGImage)
    }

    // MARK: - 重置

    func reset() {
        model2x = nil
        model4x = nil
        modelRealESRGANAnime4x = nil
        model2xLoadFailed = false
        model4xLoadFailed = false
        modelRealESRGANAnime4xLoadFailed = false
        tileSize2x = 128
        tileSize4x = 128
        tileSizeRealESRGANAnime4x = 256
    }
}

// MARK: - UIImage 扩展

private extension UIImage {
    func toPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue, kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        guard let cgImage = self.cgImage else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    func toMLMultiArray(shape: [NSNumber], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        // ✅ 验证形状：期望 [1, 3, H, W] (NCHW) 或 [1, H, W, 3] (NHWC)
        guard shape.count == 4 else {
            throw UpscaleError.preprocessingFailed
        }
        let targetHeight: Int
        let targetWidth: Int
        if shape[1].intValue == 3 {
            // NCHW: [1, 3, H, W]
            targetHeight = shape[2].intValue
            targetWidth = shape[3].intValue
        } else if shape[3].intValue == 3 {
            // NHWC: [1, H, W, 3]
            targetHeight = shape[1].intValue
            targetWidth = shape[2].intValue
        } else {
            throw UpscaleError.preprocessingFailed
        }

        guard let cgImage = self.cgImage else { throw UpscaleError.preprocessingFailed }

        let array = try MLMultiArray(shape: shape, dataType: dataType)
        var rawData = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        guard let context = CGContext(data: &rawData, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: targetWidth * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw UpscaleError.preprocessingFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        let channelSize = targetHeight * targetWidth
        switch dataType {
        case .float32:
            array.withUnsafeMutableBytes { buffer, _ in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float32.self) else { return }
                for i in 0..<channelSize {
                    let p = i * 4
                    ptr[i] = Float32(rawData[p]) / 255.0
                    ptr[channelSize + i] = Float32(rawData[p + 1]) / 255.0
                    ptr[2 * channelSize + i] = Float32(rawData[p + 2]) / 255.0
                }
            }
        case .float16:
            array.withUnsafeMutableBytes { buffer, _ in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float16.self) else { return }
                for i in 0..<channelSize {
                    let p = i * 4
                    ptr[i] = Float16(rawData[p]) / Float16(255.0)
                    ptr[channelSize + i] = Float16(rawData[p + 1]) / Float16(255.0)
                    ptr[2 * channelSize + i] = Float16(rawData[p + 2]) / Float16(255.0)
                }
            }
        default:
            throw UpscaleError.preprocessingFailed
        }
        return array
    }

    static func image(from multiArray: MLMultiArray) throws -> UIImage {
        let shape = multiArray.shape.map { Int(truncating: $0) }

        // ✅ 验证形状：期望 [1, 3, H, W] (NCHW) 或 [1, H, W, 3] (NHWC)
        guard shape.count == 4 else {
            throw UpscaleError.preprocessingFailed
        }

        let height: Int
        let width: Int
        let isNCHW: Bool

        if shape[1] == 3 {
            // NCHW: [1, 3, H, W]
            height = shape[2]
            width = shape[3]
            isNCHW = true
        } else if shape[3] == 3 {
            // NHWC: [1, H, W, 3]
            height = shape[1]
            width = shape[2]
            isNCHW = false
        } else {
            throw UpscaleError.preprocessingFailed
        }

        let channelSize = height * width
        var rawData = [UInt8](repeating: 0, count: width * height * 4)

        switch multiArray.dataType {
        case .float32:
            multiArray.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float32.self) else { return }
                if isNCHW {
                    // NCHW: [R, G, B] 通道分离
                    for i in 0..<channelSize {
                        let p = i * 4
                        rawData[p] = UInt8(max(0, min(255, ptr[i] * 255.0)))
                        rawData[p + 1] = UInt8(max(0, min(255, ptr[channelSize + i] * 255.0)))
                        rawData[p + 2] = UInt8(max(0, min(255, ptr[2 * channelSize + i] * 255.0)))
                        rawData[p + 3] = 255
                    }
                } else {
                    // NHWC: [R, G, B] 连续
                    for i in 0..<channelSize {
                        let p = i * 4
                        let s = i * 3
                        rawData[p] = UInt8(max(0, min(255, ptr[s] * 255.0)))
                        rawData[p + 1] = UInt8(max(0, min(255, ptr[s + 1] * 255.0)))
                        rawData[p + 2] = UInt8(max(0, min(255, ptr[s + 2] * 255.0)))
                        rawData[p + 3] = 255
                    }
                }
            }
        case .float16:
            multiArray.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float16.self) else { return }
                if isNCHW {
                    for i in 0..<channelSize {
                        let p = i * 4
                        rawData[p] = UInt8(max(0, min(255, Float(ptr[i]) * 255.0)))
                        rawData[p + 1] = UInt8(max(0, min(255, Float(ptr[channelSize + i]) * 255.0)))
                        rawData[p + 2] = UInt8(max(0, min(255, Float(ptr[2 * channelSize + i]) * 255.0)))
                        rawData[p + 3] = 255
                    }
                } else {
                    for i in 0..<channelSize {
                        let p = i * 4
                        let s = i * 3
                        rawData[p] = UInt8(max(0, min(255, Float(ptr[s]) * 255.0)))
                        rawData[p + 1] = UInt8(max(0, min(255, Float(ptr[s + 1]) * 255.0)))
                        rawData[p + 2] = UInt8(max(0, min(255, Float(ptr[s + 2]) * 255.0)))
                        rawData[p + 3] = 255
                    }
                }
            }
        default:
            throw UpscaleError.preprocessingFailed
        }

        let cgImage = rawData.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)?.makeImage()
        }
        guard let finalImage = cgImage else { throw UpscaleError.preprocessingFailed }
        return UIImage(cgImage: finalImage)
    }

    func resize(to targetSize: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: targetSize).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Padding 到指定尺寸（用黑色填充）
    func padToSize(targetSize: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: targetSize).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 从左上角裁剪到指定尺寸
    func cropToSize(targetSize: CGSize) -> UIImage {
        guard let cgImage = cgImage else { return self }
        let cropRect = CGRect(origin: .zero, size: targetSize)
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: croppedCGImage)
    }

    convenience init?(pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else { return nil }
        self.init(cgImage: cgImage)
    }
}
