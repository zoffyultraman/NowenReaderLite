import CoreML
import UIKit

// MARK: - 超分模式

enum UpscaleMode: String, CaseIterable, Identifiable {
    case off = "关闭"
    case x4 = "Anime4K-A-HQ x4"
    case realesrganAnime4x = "RealESRGAN Anime 4x"
    var id: String { rawValue }
}

enum UpscaleSkipThreshold: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case p1200 = 1200
    case p1600 = 1600
    case p2000 = 2000
    case p2400 = 2400

    var id: Int { rawValue }

    var shortTitle: String {
        switch self {
        case .off: return "不跳过"
        default: return "≥ \(rawValue) px"
        }
    }

    var menuTitle: String {
        switch self {
        case .off: return "不跳过（始终超分）"
        case .p1200: return "≥ 1200 px（iPhone 宽度）"
        case .p1600: return "≥ 1600 px（推荐）"
        case .p2000: return "≥ 2000 px（仅超高清）"
        case .p2400: return "≥ 2400 px"
        }
    }
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

// 所有推理入口均由 ReaderUpscaleScheduler 串行调用。
final class ImageUpscaler: @unchecked Sendable {
    static let shared = ImageUpscaler()

    private var model4x: MLModel?
    private var modelRealESRGANAnime4x: MLModel?
    private var model4xLoadFailed = false
    private var modelRealESRGANAnime4xLoadFailed = false
    private var tileSize4x: Int = 128
    private var tileSizeRealESRGANAnime4x: Int = 256
    fileprivate static let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

    private init() {}

    // MARK: - 模型加载

    private func loadModel4x() throws -> MLModel {
        if let model = model4x { return model }
        if model4xLoadFailed { throw UpscaleError.modelNotFound("anime4k-4x-a-hq") }
        guard let modelURL = Bundle.main.url(forResource: "anime4k-4x-a-hq", withExtension: "mlmodelc") ??
                Bundle.main.url(forResource: "anime4k-4x-a-hq", withExtension: "mlpackage") else {
            model4xLoadFailed = true
            throw UpscaleError.modelNotFound("anime4k-4x-a-hq")
        }
        do {
            modelRealESRGANAnime4x = nil
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
            model4x = nil
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
            if name == "4x" { tileSize4x = detectedSize }
            else if name == "RealESRGAN Anime 4x" { tileSizeRealESRGANAnime4x = detectedSize }
        }
    }

    // MARK: - 超分推理

    static func shouldSkipUpscale(
        for image: UIImage,
        skipThreshold: UpscaleSkipThreshold
    ) -> Bool {
        guard skipThreshold.rawValue > 0 else { return false }
        let width: CGFloat
        let height: CGFloat
        if let cgImage = image.cgImage {
            width = CGFloat(cgImage.width)
            height = CGFloat(cgImage.height)
        } else {
            width = image.size.width * image.scale
            height = image.size.height * image.scale
        }
        return min(width, height) >= CGFloat(skipThreshold.rawValue)
    }

    func upscale(
        _ image: UIImage,
        mode: UpscaleMode,
        keepOriginalSize: Bool = false,
        maxOutputBytes: Int = 64 * 1024 * 1024,
        skipThreshold: UpscaleSkipThreshold = .off,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> UIImage {
        if isCancelled() { throw CancellationError() }
        guard mode != .off else { return image }
        if Self.shouldSkipUpscale(for: image, skipThreshold: skipThreshold) {
            return image
        }

        // 内存上限检查：与 ReaderCacheManager.upscaledBudget / 4 对齐，确保至少 4 页可同时驻留缓存
        let absoluteMax: CGFloat = 4096
        let maxOutputDimension: CGFloat = 8192
        let maxOutputPixels = CGFloat(max(8_000_000, maxOutputBytes / 4))
        let imageWidth: CGFloat
        let imageHeight: CGFloat
        if let cgImage = image.cgImage {
            imageWidth = CGFloat(cgImage.width)
            imageHeight = CGFloat(cgImage.height)
        } else {
            imageWidth = image.size.width * image.scale
            imageHeight = image.size.height * image.scale
        }

        if imageWidth > absoluteMax || imageHeight > absoluteMax {
            throw UpscaleError.preprocessingFailed
        }

        let model: MLModel
        let tileSize: Int
        let scaleFactor: CGFloat
        let pixelCount = imageWidth * imageHeight
        let maxDim = max(imageWidth, imageHeight)

        if keepOriginalSize {
            guard pixelCount <= maxOutputPixels else {
                throw UpscaleError.preprocessingFailed
            }
            scaleFactor = 1.0
        } else {
            let canUse4x = pixelCount * 16 <= maxOutputPixels && maxDim * 4 <= maxOutputDimension
            let canUse3x = pixelCount * 9 <= maxOutputPixels && maxDim * 3 <= maxOutputDimension
            let canUse2x = pixelCount * 4 <= maxOutputPixels && maxDim * 2 <= maxOutputDimension

            if canUse4x {
                scaleFactor = 4.0
            } else if canUse3x {
                scaleFactor = 3.0
            } else if canUse2x {
                scaleFactor = 2.0
            } else if pixelCount <= maxOutputPixels {
                scaleFactor = 1.0
            } else {
                throw UpscaleError.preprocessingFailed
            }
        }

        switch mode {
        case .x4:
            model = try loadModel4x()
            tileSize = tileSize4x
        case .realesrganAnime4x:
            model = try loadModelRealESRGANAnime4x()
            tileSize = tileSizeRealESRGANAnime4x
        case .off:
            return image
        }

        if isCancelled() { throw CancellationError() }

        // ✅ RealESRGAN 模型强制使用 TensorType 输入
        let forceTensorInput = (mode == .realesrganAnime4x)

        let resultImage = try tileInference(
            image: image,
            model: model,
            tileSize: tileSize,
            scaleFactor: scaleFactor,
            forceTensorInput: forceTensorInput,
            isCancelled: isCancelled
        )

        if keepOriginalSize, let cg = resultImage.cgImage {
            return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
        }

        return resultImage
    }

    // MARK: - Tile 推理核心（tilePad 上下文扩展）

    private func tileInference(
        image: UIImage,
        model: MLModel,
        tileSize: Int,
        scaleFactor: CGFloat,
        forceTensorInput: Bool = false,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> UIImage {
        guard let cgImage = image.cgImage else { throw UpscaleError.invalidImage }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        let scale = Int(scaleFactor)

        // tilePad: 每个 tile 内部的上下文扩展像素数
        // 有效区域 = tileSize - 2 * tilePad = 256 - 32 = 224
        // 模型始终接收 256×256 输入，边缘 16px 是上下文，推理后裁剪掉
        let tilePad = 16
        let effectiveSize = tileSize - 2 * tilePad  // 224
        let stride = effectiveSize

        // 步骤 1: 计算 tile 网格（基于有效区域步进）
        let tilesX = (imageWidth + stride - 1) / stride
        let tilesY = (imageHeight + stride - 1) / stride

        // 步骤 2: 创建输出 CGContext（CG 坐标系，无变换）
        // data: nil 让 CGContext 自行管理缓冲区，避免 Swift Array 预分配 OOM
        let finalWidth = imageWidth * scale
        let finalHeight = imageHeight * scale

        guard let outputCtx = CGContext(
            data: nil,
            width: finalWidth,
            height: finalHeight,
            bitsPerComponent: 8,
            bytesPerRow: finalWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw UpscaleError.preprocessingFailed
        }
        outputCtx.interpolationQuality = .high

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

        // 步骤 3: 处理每个 tile（复用临时像素缓冲 + autoreleasepool 及时释放 CoreML/CoreImage 临时对象）
        var failedTiles = 0
        var inputScratchBuffer: [UInt8] = []
        var outputScratchBuffer: [UInt8] = []

        for gridY in 0..<tilesY {
            for gridX in 0..<tilesX {
                if isCancelled() { throw CancellationError() }

                try autoreleasepool {
                    // 3a. 有效区域在原图中的坐标和实际尺寸
                    let effX = gridX * stride
                    let effY = gridY * stride
                    let effW = min(effectiveSize, imageWidth - effX)
                    let effH = min(effectiveSize, imageHeight - effY)

                    // 3b. 以有效区域为中心，向四周扩展 tilePad，精确计算每侧 pad 量
                    let padLeft = tilePad - min(tilePad, effX)
                    let padTop = tilePad - min(tilePad, effY)
                    let padRight = tilePad - min(tilePad, imageWidth - (effX + effW))
                    let padBottom = tilePad - min(tilePad, imageHeight - (effY + effH))

                    // 3c. 从原图裁剪实际可用区域
                    let cropX = max(0, effX - tilePad)
                    let cropY = max(0, effY - tilePad)
                    let cropW = min(tileSize - padLeft - padRight, imageWidth - cropX)
                    let cropH = min(tileSize - padTop - padBottom, imageHeight - cropY)

                    guard cropW > 0 && cropH > 0,
                          let tileCGImage = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) else {
                        return
                    }
                    let tileUIImage = UIImage(cgImage: tileCGImage)

                    // 3d. 精确 pad 到 tileSize×tileSize（仅在需要时，避免二次插值）
                    let paddedImage: UIImage
                    if padLeft > 0 || padTop > 0 || padRight > 0 || padBottom > 0 {
                        paddedImage = tileUIImage.padTo(
                            left: padLeft, top: padTop,
                            right: padRight, bottom: padBottom,
                            targetSize: CGSize(width: tileSize, height: tileSize)
                        )
                    } else {
                        paddedImage = tileUIImage
                    }

                    // 3e. 创建输入
                    let inputFeature: MLFeatureProvider
                    if inputDesc.type == .multiArray, let constraint = inputDesc.multiArrayConstraint {
                        let multiArray = try paddedImage.toMLMultiArray(
                            shape: constraint.shape,
                            dataType: constraint.dataType,
                            scratchBuffer: &inputScratchBuffer
                        )
                        inputFeature = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: multiArray)])
                    } else if inputDesc.type == .image && !forceTensorInput {
                        guard let pixelBuffer = paddedImage.toPixelBuffer(width: tileSize, height: tileSize) else { return }
                        inputFeature = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
                    } else {
                        if forceTensorInput { throw UpscaleError.preprocessingFailed }
                        return
                    }

                    // 3f. 推理
                    let output: MLFeatureProvider
                    do {
                        output = try model.prediction(from: inputFeature)
                    } catch {
                        failedTiles += 1
                        return
                    }
                    if isCancelled() { throw CancellationError() }

                    // 3g. 获取输出，按模型实际倍率裁剪上下文区域，并缩放到目标倍率绘制到输出 CGContext
                    if let outputValue = output.featureValue(for: outputName) {
                        let outputTile: UIImage?
                        if outputValue.type == .multiArray, let multiArray = outputValue.multiArrayValue {
                            do {
                                outputTile = try UIImage.image(
                                    from: multiArray,
                                    scratchBuffer: &outputScratchBuffer
                                )
                            } catch {
                                failedTiles += 1
                                return
                            }
                        } else if outputValue.type == .image, let pixelBuffer = outputValue.imageBufferValue {
                            outputTile = UIImage(pixelBuffer: pixelBuffer)
                        } else {
                            failedTiles += 1
                            outputTile = nil
                        }

                        if let outputTile = outputTile, let outputCGImage = outputTile.cgImage {
                            let modelScale = max(1, outputCGImage.width / tileSize)
                            let srcPad = tilePad * modelScale
                            let srcValid = effectiveSize * modelScale
                            let dstValid = effectiveSize * scale
                            if let croppedCG = outputCGImage.cropping(to: CGRect(
                                x: srcPad, y: srcPad,
                                width: srcValid, height: srcValid
                            )) {
                                let dstX = gridX * dstValid
                                let dstY = finalHeight - (gridY * dstValid + dstValid)
                                outputCtx.draw(croppedCG, in: CGRect(x: dstX, y: dstY, width: dstValid, height: dstValid))
                            }
                        }
                    }
                }
            }
        }

        // ✅ 检查是否有太多 tile 失败
        if isCancelled() { throw CancellationError() }
        let totalTiles = tilesX * tilesY
        if failedTiles == totalTiles {
            throw UpscaleError.inferenceFailed(NSError(domain: "ImageUpscaler", code: -1, userInfo: [NSLocalizedDescriptionKey: "All tiles failed inference"]))
        }

        // 步骤 4: 生成最终图像
        guard let finalCGImage = outputCtx.makeImage() else {
            throw UpscaleError.preprocessingFailed
        }

        return UIImage(cgImage: finalCGImage)
    }

    // MARK: - 重置

    func reset() {
        model4x = nil
        modelRealESRGANAnime4x = nil
        model4xLoadFailed = false
        modelRealESRGANAnime4xLoadFailed = false
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

    func toMLMultiArray(
        shape: [NSNumber],
        dataType: MLMultiArrayDataType,
        scratchBuffer: inout [UInt8]
    ) throws -> MLMultiArray {
        // 支持 NCHW [1, C, H, W] 和 NHWC [1, H, W, C]，C 为 3 的倍数
        guard shape.count == 4 else {
            throw UpscaleError.preprocessingFailed
        }
        let channels: Int
        let targetHeight: Int
        let targetWidth: Int
        let isNCHW: Bool
        if shape[1].intValue % 3 == 0 {
            // NCHW: [1, C, H, W]
            channels = shape[1].intValue
            targetHeight = shape[2].intValue
            targetWidth = shape[3].intValue
            isNCHW = true
        } else if shape[3].intValue % 3 == 0 {
            // NHWC: [1, H, W, C]
            channels = shape[3].intValue
            targetHeight = shape[1].intValue
            targetWidth = shape[2].intValue
            isNCHW = false
        } else {
            throw UpscaleError.preprocessingFailed
        }

        guard let cgImage = self.cgImage else { throw UpscaleError.preprocessingFailed }

        let array = try MLMultiArray(shape: shape, dataType: dataType)
        let neededBytes = targetWidth * targetHeight * 4
        if scratchBuffer.count != neededBytes {
            scratchBuffer = [UInt8](repeating: 0, count: neededBytes)
        }
        guard let context = scratchBuffer.withUnsafeMutableBytes({ buffer -> CGContext? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return CGContext(
                data: baseAddress,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
        }) else {
            throw UpscaleError.preprocessingFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        let channelSize = targetHeight * targetWidth
        let rgbCopies = channels / 3  // 12通道 = 4组RGB
        let strides = array.strides.map(\.intValue)
        let strideC = isNCHW ? strides[1] : strides[3]
        let strideH = isNCHW ? strides[2] : strides[1]
        let strideW = isNCHW ? strides[3] : strides[2]
        let isContiguous = isNCHW
            ? (strideW == 1 && strideH == targetWidth && strideC == channelSize)
            : (strideC == 1 && strideW == channels && strideH == targetWidth * channels)

        switch dataType {
        case .float32:
            array.withUnsafeMutableBytes { buffer, _ in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float32.self) else { return }
                let scale: Float32 = 1.0 / 255.0
                if isContiguous {
                    if isNCHW {
                        for i in 0..<channelSize {
                            let p = i * 4
                            let r = Float32(scratchBuffer[p]) * scale
                            let g = Float32(scratchBuffer[p + 1]) * scale
                            let b = Float32(scratchBuffer[p + 2]) * scale
                            for copy in 0..<rgbCopies {
                                let base = copy * 3 * channelSize
                                ptr[base + i] = r
                                ptr[base + channelSize + i] = g
                                ptr[base + 2 * channelSize + i] = b
                            }
                        }
                    } else {
                        for i in 0..<channelSize {
                            let p = i * 4
                            let r = Float32(scratchBuffer[p]) * scale
                            let g = Float32(scratchBuffer[p + 1]) * scale
                            let b = Float32(scratchBuffer[p + 2]) * scale
                            let base = i * channels
                            for copy in 0..<rgbCopies {
                                ptr[base + copy * 3] = r
                                ptr[base + copy * 3 + 1] = g
                                ptr[base + copy * 3 + 2] = b
                            }
                        }
                    }
                } else {
                    for y in 0..<targetHeight {
                        let rowOffset = y * targetWidth
                        let yStride = y * strideH
                        for x in 0..<targetWidth {
                            let p = (rowOffset + x) * 4
                            let r = Float32(scratchBuffer[p]) * scale
                            let g = Float32(scratchBuffer[p + 1]) * scale
                            let b = Float32(scratchBuffer[p + 2]) * scale
                            let xyOffset = yStride + x * strideW
                            for copy in 0..<rgbCopies {
                                let cBase = copy * 3
                                ptr[xyOffset + cBase * strideC] = r
                                ptr[xyOffset + (cBase + 1) * strideC] = g
                                ptr[xyOffset + (cBase + 2) * strideC] = b
                            }
                        }
                    }
                }
            }
        case .float16:
            array.withUnsafeMutableBytes { buffer, _ in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float16.self) else { return }
                let scale: Float = 1.0 / 255.0
                if isContiguous {
                    if isNCHW {
                        for i in 0..<channelSize {
                            let p = i * 4
                            let r = Float16(Float(scratchBuffer[p]) * scale)
                            let g = Float16(Float(scratchBuffer[p + 1]) * scale)
                            let b = Float16(Float(scratchBuffer[p + 2]) * scale)
                            for copy in 0..<rgbCopies {
                                let base = copy * 3 * channelSize
                                ptr[base + i] = r
                                ptr[base + channelSize + i] = g
                                ptr[base + 2 * channelSize + i] = b
                            }
                        }
                    } else {
                        for i in 0..<channelSize {
                            let p = i * 4
                            let r = Float16(Float(scratchBuffer[p]) * scale)
                            let g = Float16(Float(scratchBuffer[p + 1]) * scale)
                            let b = Float16(Float(scratchBuffer[p + 2]) * scale)
                            let base = i * channels
                            for copy in 0..<rgbCopies {
                                ptr[base + copy * 3] = r
                                ptr[base + copy * 3 + 1] = g
                                ptr[base + copy * 3 + 2] = b
                            }
                        }
                    }
                } else {
                    for y in 0..<targetHeight {
                        let rowOffset = y * targetWidth
                        let yStride = y * strideH
                        for x in 0..<targetWidth {
                            let p = (rowOffset + x) * 4
                            let r = Float16(Float(scratchBuffer[p]) * scale)
                            let g = Float16(Float(scratchBuffer[p + 1]) * scale)
                            let b = Float16(Float(scratchBuffer[p + 2]) * scale)
                            let xyOffset = yStride + x * strideW
                            for copy in 0..<rgbCopies {
                                let cBase = copy * 3
                                ptr[xyOffset + cBase * strideC] = r
                                ptr[xyOffset + (cBase + 1) * strideC] = g
                                ptr[xyOffset + (cBase + 2) * strideC] = b
                            }
                        }
                    }
                }
            }
        default:
            throw UpscaleError.preprocessingFailed
        }
        return array
    }

    static func image(from multiArray: MLMultiArray, scratchBuffer: inout [UInt8]) throws -> UIImage {
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
        let neededBytes = width * height * 4
        if scratchBuffer.count != neededBytes {
            scratchBuffer = [UInt8](repeating: 0, count: neededBytes)
        }
        let strides = multiArray.strides.map(\.intValue)
        let strideC = isNCHW ? strides[1] : strides[3]
        let strideH = isNCHW ? strides[2] : strides[1]
        let strideW = isNCHW ? strides[3] : strides[2]
        let isContiguous = isNCHW
            ? (strideW == 1 && strideH == width && strideC == channelSize)
            : (strideC == 1 && strideW == 3 && strideH == width * 3)

        switch multiArray.dataType {
        case .float32:
            multiArray.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float32.self) else { return }
                if isContiguous {
                    if isNCHW {
                        for i in 0..<channelSize {
                            let p = i * 4
                            scratchBuffer[p] = UInt8(max(0, min(255, ptr[i] * 255.0)))
                            scratchBuffer[p + 1] = UInt8(max(0, min(255, ptr[channelSize + i] * 255.0)))
                            scratchBuffer[p + 2] = UInt8(max(0, min(255, ptr[2 * channelSize + i] * 255.0)))
                            scratchBuffer[p + 3] = 255
                        }
                    } else {
                        for i in 0..<channelSize {
                            let p = i * 4
                            let s = i * 3
                            scratchBuffer[p] = UInt8(max(0, min(255, ptr[s] * 255.0)))
                            scratchBuffer[p + 1] = UInt8(max(0, min(255, ptr[s + 1] * 255.0)))
                            scratchBuffer[p + 2] = UInt8(max(0, min(255, ptr[s + 2] * 255.0)))
                            scratchBuffer[p + 3] = 255
                        }
                    }
                } else {
                    for y in 0..<height {
                        let rowOffset = y * width
                        let yStride = y * strideH
                        for x in 0..<width {
                            let p = (rowOffset + x) * 4
                            let xy = yStride + x * strideW
                            scratchBuffer[p] = UInt8(max(0, min(255, ptr[xy] * 255.0)))
                            scratchBuffer[p + 1] = UInt8(max(0, min(255, ptr[xy + strideC] * 255.0)))
                            scratchBuffer[p + 2] = UInt8(max(0, min(255, ptr[xy + 2 * strideC] * 255.0)))
                            scratchBuffer[p + 3] = 255
                        }
                    }
                }
            }
        case .float16:
            multiArray.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: Float16.self) else { return }
                if isContiguous {
                    if isNCHW {
                        for i in 0..<channelSize {
                            let p = i * 4
                            scratchBuffer[p] = UInt8(max(0, min(255, Float(ptr[i]) * 255.0)))
                            scratchBuffer[p + 1] = UInt8(max(0, min(255, Float(ptr[channelSize + i]) * 255.0)))
                            scratchBuffer[p + 2] = UInt8(max(0, min(255, Float(ptr[2 * channelSize + i]) * 255.0)))
                            scratchBuffer[p + 3] = 255
                        }
                    } else {
                        for i in 0..<channelSize {
                            let p = i * 4
                            let s = i * 3
                            scratchBuffer[p] = UInt8(max(0, min(255, Float(ptr[s]) * 255.0)))
                            scratchBuffer[p + 1] = UInt8(max(0, min(255, Float(ptr[s + 1]) * 255.0)))
                            scratchBuffer[p + 2] = UInt8(max(0, min(255, Float(ptr[s + 2]) * 255.0)))
                            scratchBuffer[p + 3] = 255
                        }
                    }
                } else {
                    for y in 0..<height {
                        let rowOffset = y * width
                        let yStride = y * strideH
                        for x in 0..<width {
                            let p = (rowOffset + x) * 4
                            let xy = yStride + x * strideW
                            scratchBuffer[p] = UInt8(max(0, min(255, Float(ptr[xy]) * 255.0)))
                            scratchBuffer[p + 1] = UInt8(max(0, min(255, Float(ptr[xy + strideC]) * 255.0)))
                            scratchBuffer[p + 2] = UInt8(max(0, min(255, Float(ptr[xy + 2 * strideC]) * 255.0)))
                            scratchBuffer[p + 3] = 255
                        }
                    }
                }
            }
        default:
            throw UpscaleError.preprocessingFailed
        }

        let cgImage = scratchBuffer.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)?.makeImage()
        }
        guard let finalImage = cgImage else { throw UpscaleError.preprocessingFailed }
        return UIImage(cgImage: finalImage)
    }

    func resize(to targetSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Padding 到指定尺寸（用黑色填充）
    func padToSize(targetSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 精确非对称 padding：在指定方向添加黑边，图像放置在 (left, top) 位置
    func padTo(left: Int, top: Int, right: Int, bottom: Int, targetSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            draw(in: CGRect(x: CGFloat(left), y: CGFloat(top), width: size.width, height: size.height))
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
        guard let cgImage = ImageUpscaler.sharedCIContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        self.init(cgImage: cgImage)
    }
}
