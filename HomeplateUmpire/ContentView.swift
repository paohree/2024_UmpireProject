import SwiftUI  // SwiftUI 프레임워크 임포트
import AVFoundation  // 오디오 및 비디오 처리를 위한 프레임워크
import Vision  // Vision 프레임워크로 객체 인식 및 추적

// SwiftUI에서 UIKit의 UIViewController를 사용하기 위한 struct
struct CameraView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let cameraViewController = CameraViewController()  // 카메라를 사용하는 뷰컨트롤러 생성
        return cameraViewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // 이 부분에서는 UIViewController 업데이트 로직 필요 없음
    }
}

// 카메라 제어 및 객체 인식을 위한 뷰컨트롤러 클래스
class CameraViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var captureSession = AVCaptureSession()  // 카메라 세션을 관리하는 객체
    var previewLayer: AVCaptureVideoPreviewLayer?  // 카메라 미리보기 레이어
    var requests = [VNRequest]()  // Vision 프레임워크에서 실행할 요청 목록
    var strikeZone: CGRect?  // 스트라이크 존의 위치와 크기 저장
    
    let speechSynthesizer = AVSpeechSynthesizer()  // 텍스트를 음성으로 변환해주는 객체
    var frameCount = 0  // 프레임 카운터

    override func viewDidLoad() {
        super.viewDidLoad()

        // 카메라 설정 함수 호출
        configureCamera()

        // 카메라 미리보기 레이어 설정
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer?.videoGravity = .resizeAspectFill  // 화면에 맞게 미리보기 채움
        view.layer.addSublayer(previewLayer!)  // 미리보기 레이어를 화면에 추가

        // Vision 프레임워크 설정
        setupVision()

        // 카메라 세션 시작
        captureSession.startRunning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds  // 카메라 미리보기 레이어를 화면 크기에 맞게 조정
    }

    // 카메라 설정 (FPS 120으로 설정)
    func configureCamera() {
        guard let camera = AVCaptureDevice.default(for: .video) else { return }
        
        do {
            // 카메라 프레임 속도를 120 FPS로 설정
            if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 120 }) {
                try camera.lockForConfiguration()
                camera.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 120)  // 최소 프레임 속도 120 FPS
                camera.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 120)  // 최대 프레임 속도 120 FPS
                camera.unlockForConfiguration()
            }
            
            let input = try AVCaptureDeviceInput(device: camera)  // 카메라 입력을 설정
            captureSession.addInput(input)  // 입력을 세션에 추가
        } catch {
            print("Error setting up camera input: \(error)")  // 오류 발생 시 출력
            return
        }

        // 비디오 프레임을 처리할 델리게이트 설정
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        captureSession.addOutput(videoOutput)  // 세션에 비디오 출력 추가
    }

    // Vision 프레임워크 요청 설정
    func setupVision() {
        let bodyDetectionRequest = VNDetectHumanRectanglesRequest { (request, error) in
            if let results = request.results as? [VNDetectedObjectObservation], !results.isEmpty {
                
                // 감지된 사람들 중 타자만 인식
                var detectedHumans = results
                
                if detectedHumans.count > 1 {
                    // 세로 크기가 더 큰 사람을 타자로 인식 (포수는 앉아있기 때문에 더 작음)
                    detectedHumans.sort { $0.boundingBox.height > $1.boundingBox.height }
                    let batter = detectedHumans.first!  // 세로로 가장 큰 사람을 타자로 간주
                    setStrikeZone(for: batter)  // 타자에 대한 스트라이크 존 설정
                } else {
                    // 사람이 한 명이라면 그 사람을 타자로 간주
                    let batter = detectedHumans.first!
                    setStrikeZone(for: batter)
                }
            }
        }
        self.requests = [bodyDetectionRequest]  // Vision 요청을 배열에 추가
    }

    // 타자를 기반으로 스트라이크 존을 설정하는 함수
    func setStrikeZone(for batter: VNDetectedObjectObservation) {
        let boundingBox = batter.boundingBox
        
        // 무릎에서 허리까지 스트라이크 존 설정 (신체 비율 기준)
        let kneeY = boundingBox.origin.y + (boundingBox.height * 0.3)  // 무릎 위치
        let upperBodyY = boundingBox.origin.y + (boundingBox.height * 0.7)  // 허리와 어깨 사이

        let strikeZoneWidth: CGFloat = 0.3  // 고정된 가로 크기 설정

        // 스트라이크 존 설정
        self.strikeZone = CGRect(
            x: boundingBox.midX - (strikeZoneWidth / 2),  // 타자의 중심에 맞춰 설정
            y: kneeY,  // 무릎 위치
            width: strikeZoneWidth,  // 고정된 가로 크기
            height: upperBodyY - kneeY  // 무릎에서 허리까지의 높이
        )
        
        print("Strike zone set at: \(String(describing: self.strikeZone))")
    }

    // 공의 궤적을 추적하고 스트라이크 여부를 판정하는 함수 (프레임 간격 조정)
    func trackBallAndCheckStrike(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectRectanglesRequest { (request, error) in
            if let results = request.results as? [VNRectangleObservation] {
                for result in results {
                    let ballPosition = result.boundingBox  // 감지된 공의 위치

                    // 공이 스트라이크 존을 통과하는지 확인
                    if let strikeZone = self.strikeZone, strikeZone.contains(ballPosition) {
                        self.speak("Strike!")  // 스트라이크일 때 "Strike!" 음성 출력
                    } else {
                        self.speak("Ball!")  // 볼일 때 "Ball!" 음성 출력
                    }
                }
            }
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])  // Vision 요청 실행
    }

    // 비디오 프레임을 처리하고 객체 인식 및 공 궤적을 추적하는 함수 (매 3번째 프레임마다 처리)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        
        if frameCount % 3 == 0 {  // 매 3번째 프레임마다 Vision 요청을 수행
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            // 타자의 윤곽 인식
            let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            try? imageRequestHandler.perform(self.requests)
            
            // 공의 궤적을 추적하여 스트라이크 여부를 판정
            trackBallAndCheckStrike(sampleBuffer)
        }
    }

    // 텍스트를 음성으로 출력하는 함수
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)  // 출력할 텍스트 설정
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")  // 영어 음성 설정 (필요시 "ko-KR"로 변경 가능)
        speechSynthesizer.speak(utterance)  // 음성을 출력
    }
}

// SwiftUI에서 카메라 뷰를 표시하는 구조체
struct ContentView: View {
    var body: some View {
        VStack {
            CameraView()  // 카메라 뷰를 SwiftUI에서 호출
                .edgesIgnoringSafeArea(.all)  // 카메라 뷰가 전체 화면에 나타나도록 설정
        }
    }
}

#Preview {
    ContentView()  // 미리보기를 통해 ContentView를 확인
}
