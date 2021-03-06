import Foundation
import AVFoundation
import Capacitor
import Speech


@objc(SpeechRecognition)
public class SpeechRecognition: CAPPlugin {
    
    let DEFAULT_LANGUAGE = "en-US"
    let DEFAULT_MATCHES = 5
    let MESSAGE_MISSING_PERMISSION = "Missing permission"
    let MESSAGE_ACCESS_DENIED = "User denied access to speech recognition"
    let MESSAGE_RESTRICTED = "Speech recognition restricted on this device"
    let MESSAGE_NOT_DETERMINED = "Speech recognition not determined on this device"
    let MESSAGE_ACCESS_DENIED_MICROPHONE = "User denied access to microphone"
    let MESSAGE_ONGOING = "Ongoing speech recognition"
    let MESSAGE_UNKNOWN = "Unknown error occured"
    
    private var speechRecognizer = SFSpeechRecognizer()
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var autoTimeoutTimer: Timer?
    private var privateTransArr: AnyObject?
    private var timeout = 2
    
    private func restartSilenceTimer() {
        print("Restarting timer...")
        autoTimeoutTimer?.invalidate()
        
        autoTimeoutTimer = Timer.scheduledTimer(timeInterval: TimeInterval(self.timeout), target: self, selector: #selector(self.speechTimedOut), userInfo: nil, repeats: false)
    }
    
    private func quitSilenceTimer() {
        print("Quitting timer...")
        autoTimeoutTimer?.invalidate()
        
        autoTimeoutTimer = nil
    }

    
    @objc func available(_ call: CAPPluginCall) {
        if SFSpeechRecognizer.self != nil {
            call.success([
                "available": true
            ])
        } else {
            call.success([
                "available": false
            ])
        }
    }
    
    @objc func start(_ call: CAPPluginCall) {
        
        if self.audioEngine != nil{
            if self.audioEngine.isRunning {
                call.error(self.MESSAGE_ONGOING)
                return
        }
        }
        let status: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
        if status != SFSpeechRecognizerAuthorizationStatus.authorized {
            call.error(self.MESSAGE_MISSING_PERMISSION)
            return
        }
        
        AVAudioSession.sharedInstance().requestRecordPermission { (granted) in
            if !granted {
                call.error(self.MESSAGE_ACCESS_DENIED_MICROPHONE)
                return
            }
            
            let language: String = call.getString("language") ?? "en-US"
            let maxResults : Int = call.getInt("maxResults") ?? self.DEFAULT_MATCHES
            let partialResults : Bool = call.getBool("partialResults") ?? false
            
            if (self.recognitionTask != nil) {
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
            }
            
            let audioSession = AVAudioSession.sharedInstance()
            do {
                print("setting up audio session...")
                try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
                // try audioSession.setMode(AVAudioSession.Mode.default)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                print("error setting up audio session")
            }
            
            
            
            let inputNode = self.audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                self.recognitionRequest?.append(buffer)
            }
            
            self.audioEngine.prepare()
            do {
                try self.audioEngine.start()
            } catch {
                call.error(self.MESSAGE_UNKNOWN)
            }
            
            self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            
            guard self.recognitionRequest == self.recognitionRequest else { fatalError("Unable to create a SFSpeechAudioBufferRecognitionRequest object") }
            self.recognitionRequest?.shouldReportPartialResults = partialResults
            
            self.restartSilenceTimer()
            
            self.recognitionTask = self.speechRecognizer?.recognitionTask(with: self.recognitionRequest!, resultHandler: { (result, error) in
                var transcriptions: AnyObject?
                if (result != nil) {
                    self.restartSilenceTimer()
                    let resultArray: NSMutableArray = NSMutableArray()
                    var counter: Int = 0
                    
                    for transcription: SFTranscription in result!.transcriptions {
                        if maxResults > 0 && counter < maxResults {
                            print(transcription)
                            resultArray.add(transcription.formattedString)
                        }
                        counter+=1
                    }
                    
                    transcriptions = resultArray
                    
                    self.notifyListeners("transcription", data: ["matches": transcriptions!])
                    /* call.success([
                        "matches": transcriptions
                    ]) */
                }
                
                if (error != nil) {
                    self.audioEngine.stop()
                    self.audioEngine.inputNode.removeTap(onBus: 0)
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    self.quitSilenceTimer()
                    call.error(error!.localizedDescription)
                }
                
                if result!.isFinal {
                    self.quitSilenceTimer()
                    self.audioEngine.stop()
                    self.audioEngine.inputNode.removeTap(onBus: 0)
                    // might be unnecessary BUT this finish call is thrown in there :)
                    self.recognitionTask?.finish()
                    self.recognitionTask = nil
                    self.recognitionRequest = nil
                    print("Resolving as final...")
                    call.success([
                        "matches": transcriptions
                    ]) 
                }
            })
            
            
            
        }
    }
    
    @objc private func speechTimedOut() {
        print("Speech timed out")
        self.quitSilenceTimer()
        self.audioEngine.stop()
        self.audioEngine.inputNode.removeTap(onBus: 0)
        // might be unnecessary BUT this finish call is thrown in there :)
        self.recognitionTask?.finish()
        self.recognitionTask = nil
        self.recognitionRequest = nil
        print("Resolving as timed out/final...")
        
    }
    
    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: DispatchQoS.QoSClass.default).async {
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
                self.recognitionRequest?.endAudio()
                let inputNode: AVAudioInputNode = self.audioEngine.inputNode
                inputNode.removeTap(onBus: 0)
            }
            
            if (self.recognitionTask != nil) {
                self.recognitionTask = nil
            }
            if (self.recognitionRequest != nil) {
                self.recognitionRequest = nil
            }
            self.quitSilenceTimer()
            call.success()
        }
    }
    
    @objc func getSupportedLanguages(_ call: CAPPluginCall) {
        let supportedLanguages : Set<Locale>! = SFSpeechRecognizer.supportedLocales() as Set<Locale>
        let languagesArr : NSMutableArray = NSMutableArray()
        
        for lang: Locale in supportedLanguages {
            languagesArr.add(lang.identifier)
        }
        
        call.success([
            "languages": languagesArr
        ])
    }
    
    @objc func hasPermission(_ call: CAPPluginCall) {
        let status: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
        let speechAuthGranted : Bool = (status == SFSpeechRecognizerAuthorizationStatus.authorized)
        
        if (!speechAuthGranted) {
            call.success([
                "permission": false
            ])
            return
        }
        
        AVAudioSession.sharedInstance().requestRecordPermission { (granted: Bool) in
            call.success([
                "permission": true
            ])
        }
    }
    
    @objc func requestPermission(_ call: CAPPluginCall) {
        SFSpeechRecognizer.requestAuthorization { (status: SFSpeechRecognizerAuthorizationStatus) in
            DispatchQueue.main.async {
                var speechAuthGranted: Bool = false
                
                switch(status) {
                case SFSpeechRecognizerAuthorizationStatus.authorized:
                    speechAuthGranted = true
                    break
                    
                case SFSpeechRecognizerAuthorizationStatus.denied:
                    call.error(self.MESSAGE_ACCESS_DENIED)
                    break
                    
                case SFSpeechRecognizerAuthorizationStatus.restricted:
                    call.error(self.MESSAGE_RESTRICTED)
                    break
                    
                case SFSpeechRecognizerAuthorizationStatus.notDetermined:
                    call.error(self.MESSAGE_NOT_DETERMINED)
                    break
                    
                @unknown default:
                    call.error(self.MESSAGE_UNKNOWN)
                }
                
                if (!speechAuthGranted) {
                    return
                }
                
                AVAudioSession.sharedInstance().requestRecordPermission { (granted: Bool) in
                    if (granted) {
                        call.success()
                    } else {
                        call.error(self.MESSAGE_ACCESS_DENIED_MICROPHONE)
                    }
                }
            }

        }
    }
}
