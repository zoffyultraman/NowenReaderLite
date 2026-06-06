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

    // MARK: - Tile 推理核心

    private func tileInference(image: UIImage, model: MLModel, tileSize: Int, scaleFactor: CGFloat, forceTensorInput: Bool = false) throws -> UIImage {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        let scale = Int(scaleFactor)


        // 步骤 1: 计算 tile 网格（统一固定尺寸，边缘 tile padding）
        // 🔴 关键：所有 tile 坐标基于固定 tileSize 网格
        // 🔴 边缘 tile 做 padding 到 tileSize，推理后 crop
        let tilesX = (imageWidth + tileSize - 1) / tileSize  // 向上取整
        let tilesY = (imageHeight + tileSize - 1) / tileSize


        // 步骤 2: 创建输出 canvas（基于固定网格尺寸）
        // canvas 尺寸 = tilesX * tileSize * scale
        let canvasWidth = tilesX * tileSize * scale
        let canvasHeight = tilesY * tileSize * scale

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let outputContext = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: canvasWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw UpscaleError.preprocessingFailed
        }

        // 获取输入输出信息
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first,
              let outputName = model.modelDescription.outputDescriptionsByName.keys.first,
              let inputDesc = model.modelDescription.inputDescriptionsByName[inputName] else {
            throw UpscaleError.preprocessingFailed
        }

        // ✅ 检查输入类型是否支持
        guard inputDesc.type == .multiArray || inputDesc.type == .image else {
            throw UpscaleError.preprocessingFailed
        }

        // ✅ RealESRGAN 模型必须支持 TensorType
        if forceTensorInput && inputDesc.type != .multiArray {
            throw UpscaleError.preprocessingFailed
        }

        // 步骤 3: 处理每个 tile（基于固定网格坐标）
        var failedTiles = 0
        for gridY in 0..<tilesY {
            for gridX in 0..<tilesX {

                // 3a. 计算源坐标（实际裁剪位置）
                let srcX = gridX * tileSize
                let srcY = gridY * tileSize
                let srcW = min(tileSize, imageWidth - srcX)
                let srcH = min(tileSize, imageHeight - srcY)

                // 3b. 计算目标坐标（基于固定网格）
                // 🔴 关键：dstX, dstY 基于 gridX * tileSize * scale
                let dstX = gridX * tileSize * scale

                // 🔴 关键：CGContext 坐标系是左下角为原点（Y 轴向上）
                // 🔴 但图像数据是左上角为原点（Y 轴向下）
                // 🔴 所以需要翻转 Y 坐标，否则会上下颠倒
                let dstY = (tilesY - 1 - gridY) * tileSize * scale

                let dstW = tileSize * scale  // 固定尺寸，不是 srcW * scale
                let dstH = tileSize * scale  // 固定尺寸，不是 srcH * scale


                // 3c. 裁剪原图得到 tile
                guard let tileCGImage = cgImage.cropping(to: CGRect(x: srcX, y: srcY, width: srcW, height: srcH)) else {
                    continue
                }
                let tileUIImage = UIImage(cgImage: tileCGImage)

                // 3d. Edge tile padding（统一到 tileSize × tileSize）
                let paddedImage: UIImage
                if srcW != tileSize || srcH != tileSize {
                    paddedImage = tileUIImage.padToSize(targetSize: CGSize(width: tileSize, height: tileSize))
                } else {
                    paddedImage = tileUIImage
                }

                // 3e. 创建输入（使用 paddedImage）
                // ✅ RealESRGAN 模型强制使用 TensorType，避免 ImageType 的颜色空间偏移
                let inputFeature: MLFeatureProvider
                if inputDesc.type == .multiArray, let constraint = inputDesc.multiArrayConstraint {
                    let multiArray = try paddedImage.toMLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
                    inputFeature = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: multiArray)])
                } else if inputDesc.type == .image && !forceTensorInput {
                    // ⚠️ ImageType 路径：仅用于非 RealESRGAN 模型（Anime4K 等）
                    guard let pixelBuffer = paddedImage.toPixelBuffer(width: tileSize, height: tileSize) else { continue }
                    inputFeature = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
                } else {
                    // ❌ RealESRGAN 模型不支持 TensorType 输入时抛出错误
                    if forceTensorInput {
                        throw UpscaleError.preprocessingFailed
                    }
                    continue
                }

                // 3f. 推理（同步）
                let output: MLFeatureProvider
                do {
                    output = try model.prediction(from: inputFeature)
                } catch {
                    failedTiles += 1
                    continue
                }

                // 3g. 获取输出（已经是 tileSize × scale 的固定尺寸）
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
                        // 3h. 绘制到 canvas（使用固定网格坐标）
                        // 🔴 关键：dstX, dstY, dstW, dstH 都是固定值
                        // 🔴 不受 srcW, srcH 影响
                        let drawRect = CGRect(x: dstX, y: dstY, width: dstW, height: dstH)
                        outputContext.draw(outputCGImage, in: drawRect)
                    }
                }
            }
        }

        // ✅ 检查是否有太多 tile 失败
        let totalTiles = tilesX * tilesY
        if failedTiles == totalTiles {
            throw UpscaleError.inferenceFailed(NSError(domain: "ImageUpscaler", code: -1, userInfo: [NSLocalizedDescriptionKey: "All tiles failed inference"]))
        }

        guard let canvasCGImage = outputContext.makeImage() else {
            throw UpscaleError.preprocessingFailed
        }

        // 步骤 4: 从 canvas 裁剪出实际图像尺寸
        // canvas 可能比实际需要的大（因为边缘 tile padding）
        let finalWidth = imageWidth * scale
        let finalHeight = imageHeight * scale

        let finalCGImage: CGImage
        if canvasWidth != finalWidth || canvasHeight != finalHeight {
            // 需要裁剪（移除边缘 padding 区域）
            guard let cropped = canvasCGImage.cropping(to: CGRect(x: 0, y: 0, width: finalWidth, height: finalHeight)) else {
                throw UpscaleError.preprocessingFailed
            }
            finalCGImage = cropped
        } else {
            finalCGImage = canvasCGImage
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
