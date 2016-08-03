import Foundation
import CoreImage
import OpenGLES
import GLKit
import AVFoundation

// Штука, которая рендерит аутпут AVCaptureSession в UIView (в данной конкретной реализации — в GLKView)
// Решение взято отсюда: http://stackoverflow.com/questions/16543075/avcapturesession-with-multiple-previews
final class CameraOutputGLKBinder {
    
    private let view: SelfBindingGLKView
    private let eaglContext: EAGLContext
    private let ciContext: CIContext
    
    init() {
        
        eaglContext = EAGLContext(API: .OpenGLES2)
        EAGLContext.setCurrentContext(eaglContext)
        
        ciContext = CIContext(EAGLContext: eaglContext, options: [kCIContextWorkingColorSpace: NSNull()])
        
        view = SelfBindingGLKView(frame: .zero, context: eaglContext)
        view.enableSetNeedsDisplay = false
    }
    
    deinit {
        if EAGLContext.currentContext() === eaglContext {
            EAGLContext.setCurrentContext(nil)
        }
    }
    
    func setUpWithAVCaptureSession(session: AVCaptureSession) -> UIView {
        
        let delegate = CameraOutputGLKBinderDelegate.sharedInstance
        
        dispatch_async(delegate.queue) {
            
            delegate.binders.append(WeakWrapper(value: self))
            
            let output = AVCaptureVideoDataOutput()
            // CoreImage wants BGRA pixel format
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey: NSNumber(unsignedInt: kCVPixelFormatType_32BGRA)]
            output.setSampleBufferDelegate(delegate, queue: delegate.queue)
            
            do {
                try session.configure {
                    if session.canAddOutput(output) {
                        session.addOutput(output)
                    }
                }
            } catch {
                debugPrint("Couldn't configure AVCaptureSession: \(error)")
            }
        }
        
        return view
    }
}

private final class SelfBindingGLKView: GLKView {
    
    var drawableBounds: CGRect = .zero
    
    deinit {
        deleteDrawable()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        if bounds.size.width > 0 && bounds.size.height > 0 {
            bindDrawable()
            drawableBounds = CGRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight)
        }
    }
}

private final class CameraOutputGLKBinderDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    static let sharedInstance = CameraOutputGLKBinderDelegate()
    
    let queue = dispatch_queue_create("ru.avito.MediaPicker.CameraOutputGLKBinder.queue", nil)
    
    var binders = [WeakWrapper<CameraOutputGLKBinder>]()
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    @objc func captureOutput(
        captureOutput: AVCaptureOutput?,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer?,
        fromConnection connection: AVCaptureConnection?
    ) {
        guard let imageBuffer = sampleBuffer.flatMap({ CMSampleBufferGetImageBuffer($0) }) else { return }
        
        for binderWrapper in binders {
            if let binder = binderWrapper.value {
                drawImageBuffer(imageBuffer, binder: binder)
            }
        }
    }
    
    // MARK: - Private
    
    private func drawImageBuffer(imageBuffer: CVImageBuffer, binder: CameraOutputGLKBinder) {
        
        let view = binder.view
        let ciContext = binder.ciContext
        
        guard view.drawableBounds.size.width > 0 && view.drawableBounds.size.height > 0 else {
            return
        }
        
        let orientation = Int32(ExifOrientation.Left.rawValue)  // камера отдает картинку в этой ориентации

        let sourceImage = CIImage(CVPixelBuffer: imageBuffer).imageByApplyingOrientation(orientation)
        var sourceExtent = sourceImage.extent
        
        let sourceAspect = sourceExtent.size.width / sourceExtent.size.height
        let previewAspect = view.drawableBounds.size.width  / view.drawableBounds.size.height
        
        // we want to maintain the aspect radio of the screen size, so we clip the video image
        var drawRect = sourceExtent
        
        if sourceAspect > previewAspect {
            // use full height of the video image, and center crop the width
            drawRect.origin.x += (drawRect.size.width - drawRect.size.height * previewAspect) / 2
            drawRect.size.width = drawRect.size.height * previewAspect
        } else {
            // use full width of the video image, and center crop the height
            drawRect.origin.y += (drawRect.size.height - drawRect.size.width / previewAspect) / 2
            drawRect.size.height = drawRect.size.width / previewAspect
        }
        
        // clear eagl view to grey
        glClearColor(0.5, 0.5, 0.5, 1.0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        
        // set the blend mode to "source over" so that CI will use that
        glEnable(GLenum(GL_BLEND))
        glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA))
        
        ciContext.drawImage(sourceImage, inRect: view.drawableBounds, fromRect: drawRect)
        
        view.display()
    }
}