import Foundation
import ProcessRunner
import DockerProcess
import S3Kit

public enum XcodeHelperError : Error, CustomStringConvertible {
    case clean(message:String)
    //    case fetch(message:String)
    case updatePackages(message:String)
    case dockerBuild(message:String, exitCode: Int32)
    case symlinkDependencies(message:String)
    case createArchive(message:String)
    case uploadArchive(message:String)
    case gitTagParse(message:String)
    case gitTag(message:String)
    case createXcarchive(message:String)
    case xcarchivePlist(message: String)
    case unknownOption(message:String)
    public var description : String {
        get {
            switch (self) {
            case let .dockerBuild(message, _): return message
            case let .clean(message): return message
            case let .updatePackages(message): return message
            case let .symlinkDependencies(message): return message
            case let .createArchive(message): return message
            case let .uploadArchive(message): return message
            case let .gitTagParse(message): return message
            case let .gitTag(message): return message
            case let .createXcarchive(message): return message
            case let .xcarchivePlist(message): return message
            case let .unknownOption(message): return message
            }
        }
    }
}

/*public enum DockerEnvironmentVariable: String {
 case projectName = "PROJECT"
 case projectDirectory = "PROJECT_DIR"
 case commandOptions = "DOCKER_COMMAND_OPTIONS"
 case imageName = "DOCKER_IMAGE_NAME"
 case containerName = "DOCKER_CONTAINER_NAME"
 }*/


public struct XcodeHelper: XcodeHelpable {
    
    let dockerRunnable: DockerRunnable.Type
    let processRunnable: ProcessRunnable.Type
    let dateFormatter = DateFormatter()
    public let logger = Logger()
    
    public init(dockerRunnable: DockerRunnable.Type = DockerProcess.self, processRunnable: ProcessRunnable.Type = ProcessRunner.self) {
        self.dockerRunnable = dockerRunnable
        self.processRunnable = processRunnable
    }
    
    public func packagesURL(at sourcePath: String) -> URL {
        return URL(fileURLWithPath: sourcePath).appendingPathComponent(".build").appendingPathComponent("repositories")
    }
    
    //MARK: Update Packages
    // The combination of `swift package update` and persistentVolume caused "segmentation fault" and swift compiler crashes
    // For now, when we update packages in Docker we should delete all existing packages first. ie: don't persist Packges directory
    @discardableResult
    public func updateDockerPackages(at sourcePath: String, inImage dockerImageName: String, withVolume persistentVolumeName: String, shouldLog: Bool = true) throws -> ProcessResult {
        let command = Command.updateDockerPackages
        logger.log("Updating Docker packages at \(sourcePath)", for: command)
//        //backup the Packages dir
//        movePackages(at: sourcePath, fromBackup: false)
        
        //Update the Docker Packages
        let commandArgs = ["/bin/bash", "-c", "swift package update"]
        var commandOptions: [DockerRunOption] = [.volume(source: sourcePath, destination: sourcePath),//include the sourcePath
                                                 .workingDirectory(at: sourcePath)]//move to the sourcePath
        commandOptions += try persistentVolumeOptions(at: sourcePath, using: persistentVolumeName)//overwrite macOS .build with persistent volume for docker's .build dir
        var dockerProcess = dockerRunnable.init(command: "run", commandOptions: commandOptions.flatMap{ $0.processValues }, imageName: dockerImageName, commandArgs: commandArgs)
        dockerProcess.processRunnable = self.processRunnable
        let result = dockerProcess.launch(printOutput: true, outputPrefix: dockerImageName)
        if let error = result.error, result.exitCode != 0 {
            let message = "\(persistentVolumeName) - Error updating packages (\(result.exitCode)):\n\(error)"
            logger.log(message, for: command)
            throw XcodeHelperError.updatePackages(message: message)
        }
        
//        //Restore the Packages directory
//        movePackages(at: sourcePath, fromBackup: true)
        logger.log("Packages updated", for: command)
        return result
    }
    func movePackages(at sourcePath: String, fromBackup: Bool) {
        let originalURL = packagesURL(at: sourcePath)
        let backupURL = originalURL.appendingPathExtension("backup")
        let arguments = fromBackup ? [backupURL.path, originalURL.path] : [originalURL.path, backupURL.path]
        
        processRunnable.synchronousRun("/bin/mv", arguments: arguments, printOutput: false, outputPrefix: nil, environment: nil)
    }
    
    @discardableResult
    public func updateMacOsPackages(at sourcePath: String, shouldLog: Bool = true) throws -> ProcessResult {
        var output = ""
        var error = ""
        let command = Command.updateMacOSPackages
        logger.log("Updating macOS packages at \(sourcePath)", for: command)
        let process = try? ProcessRunner.init(launchPath: "/bin/bash",
                                              arguments: ["-c", "cd \(sourcePath) && swift package update"],
                                              environment: nil,
                                              stdOut: { output += self.logger.log($0, for: command) },
                                              stdErr: { error += self.logger.log($0, for: command)})
        process!.launch()
        if let executingProcess = process?.executingProcess {
            while executingProcess.isRunning {
                RunLoop.current.run(until: Date.init(timeIntervalSinceNow: TimeInterval(0.10)))
            }
        }
        self.logger.log("Packages updated", for: command)
        return (output, error, process!.executingProcess.terminationStatus)
    }
    
    @discardableResult
    public func generateXcodeProject(at sourcePath: String, shouldLog: Bool = true) throws -> ProcessResult {
        logger.log("Generating Xcode Project", for: .updateMacOSPackages)
        let result = ProcessRunner.synchronousRun("/bin/bash", arguments: ["-c", "cd \(sourcePath) && swift package generate-xcodeproj"])
        if let error = result.error, result.exitCode != 0 {
            let message = "Error generating Xcode project (\(result.exitCode)):\n\(error)"
            logger.log(message, for: .updateMacOSPackages)
            throw XcodeHelperError.updatePackages(message: message)
        }
        logger.log("Xcode project generated", for: .updateMacOSPackages)
        return result
    }
    
    //MARK: Build
    @discardableResult
    public func dockerBuild(_ sourcePath:String, with runOptions: [DockerRunOption]?, using configuration: BuildConfiguration, in dockerImageName:String = "swift", persistentVolumeName: String? = nil, shouldLog: Bool = true) throws -> ProcessResult {
        let command = Command.dockerBuild
        logger.log("Building in Docker - \(dockerImageName)", for: command)
        //We are using separate .build directories for each platform now.
        //We don't need to clean
//        //check if we need to clean first
//        if try shouldClean(sourcePath: sourcePath, using: configuration) {
//            logger.log("Cleaning", for: command)
//            try clean(sourcePath: sourcePath)
//        }
        var combinedRunOptions = [String]()
        if let dockerRunOptions = runOptions {
            combinedRunOptions += dockerRunOptions.flatMap{ $0.processValues } + ["-v", "\(sourcePath):\(sourcePath)", "--workdir", sourcePath]
        }
        if let volumeName = persistentVolumeName {
            combinedRunOptions += try persistentVolumeOptions(at: sourcePath, using: volumeName).flatMap{$0.processValues}
        }
        let bashCommand = ["/bin/bash", "-c", "swift build --configuration \(configuration.stringValue)"]
        let result = DockerProcess(command: "run", commandOptions: combinedRunOptions, imageName: dockerImageName, commandArgs: bashCommand).launch(printOutput: true)
        if let error = result.error, result.exitCode != 0 {
            let prefix = persistentVolumeName != nil ? "\(persistentVolumeName!) - " : ""
            let message = "\(prefix) Error building in Docker: \(error)"
            logger.log(message, for: command)
            throw XcodeHelperError.dockerBuild(message: message, exitCode: result.exitCode)
        }
        return result
    }
    //persistentBuildDirectory is a subdirectory of .build and we mount it with .build/persistentBuildDirectory/.build:sourcePath/.build and .build/buildDirName/.Packages:sourcePath/Packages so that we can use it's artifacts for future builds and don't have to keep rebuilding
    func persistentVolumeOptions(at sourcePath: String, using directoryName: String) throws -> [DockerRunOption] {
        // SomePackage/.build/
        let buildSubdirectory = URL(fileURLWithPath: sourcePath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        // SomePackage/.build/platform
        //not persisting Packages directory for now since it causes swift compiler to crash
        return [try persistentVolume(".build", in: buildSubdirectory)]//try persistentVolume("Packages", in: buildSubdirectory)]
        
    }
    func persistentVolume(_ name: String, in buildSubdirectory: URL) throws -> DockerRunOption {
        // SomePackage/.build/platform
        let sourceDirectory = buildSubdirectory.appendingPathComponent(name, isDirectory: true)// SomePackage/.build/platform/.build
        let destinationDirectory = buildSubdirectory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)// SomePackage/.build/
        
        
        //make sure that the persistent directories exist before we return volume mount points
        if !FileManager.default.fileExists(atPath: sourceDirectory.path) {
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true, attributes: nil)
        }
        return .volume(source: sourceDirectory.path, destination: destinationDirectory.path)
    }
    
    //MARK: Clean
    public func shouldClean(sourcePath: String, using configuration: BuildConfiguration) throws -> Bool {
        let yamlPath = configuration.yamlPath(inSourcePath:sourcePath)
        if FileManager.default.isReadableFile(atPath: yamlPath) {
            let yamlFile = try String(contentsOfFile: yamlPath)
            return yamlFile.contains("\"-target\",\"x86_64-apple")//if we have a file and it contains apple target, clean
        }
        
        //otherwise, clean if there is a build path but the file isn't readable
        return FileManager.default.fileExists(atPath: configuration.buildDirectory(inSourcePath: sourcePath))
    }
    
    @discardableResult
    public func clean(sourcePath:String, shouldLog: Bool = true) throws -> ProcessResult {
        logger.log("Cleaning", for: Command.updateDockerPackages)
        //We can use Process instead of firing up Docker because the end result is the same. A clean .build dir
        let result = ProcessRunner.synchronousRun("/bin/bash", arguments: ["-c", "cd \(sourcePath) && /usr/bin/swift build --clean"])
        if result.exitCode != 0, let error = result.error {
            let message = "Error cleaning: \(error)"
            logger.log(message, for: Command.updateDockerPackages)
            throw XcodeHelperError.clean(message: message)
        }
        return result
    }
    
    //MARK: Symlink Dependencies
    //useful for your project so that you don't have to keep updating paths for your dependencies when they change
    public func symlinkDependencies(at sourcePath:String, shouldLog: Bool = true) throws {
        logger.log("Symlinking dependencies", for: .updateMacOSPackages)
        //iterate Packages dir and create symlinks without the -Ver.sion.#
        let url = packagesURL(at: sourcePath)
        for versionedPackageName in try packageNames(from: sourcePath) {
            if let symlinkName = try symlink(dependencyPath: url.appendingPathComponent(versionedPackageName).path) {
                let message = "Symlink: "+"\(symlinkName) -> \(url.appendingPathComponent(versionedPackageName).path)"
                logger.log(message, for: Command.updateMacOSPackages)
                print(message)
                //update the xcode references to the symlink
                do {
                    try updateXcodeReferences(for: versionedPackageName, at: sourcePath, using: symlinkName)
                    logger.log("Updated Xcode references", for: Command.updateMacOSPackages)
                }catch let e{
                    let message = String(describing: e)
                    logger.log(message, for: Command.updateMacOSPackages)
                    throw e
                }
            }
        }
        logger.log("Symlinking done", for: .updateMacOSPackages)
    }
    func packageNames(from sourcePath: String) throws -> [String] {
        //find the Packages directory
        let packagesPath = URL(fileURLWithPath: sourcePath).appendingPathComponent(".build").appendingPathComponent("checkouts").path
        guard FileManager.default.fileExists(atPath: packagesPath)  else {
            throw XcodeHelperError.symlinkDependencies(message: "Failed to find directory: \(packagesPath)")
        }
        return try FileManager.default.contentsOfDirectory(atPath: packagesPath)
    }
    func symlink(dependencyPath: String) throws -> String? {
        let directory = URL(fileURLWithPath: dependencyPath).lastPathComponent
        if directory.hasPrefix(".") || directory.range(of: "-")?.lowerBound == nil || directory.hasSuffix("json") {
            //if it begins with . or doesn't have the - in it like XcodeHelper-1.0.0, skip it
            return nil
        }
        //remove the - version number from name and create sym link
        let packagesURL = URL(fileURLWithPath: dependencyPath).deletingLastPathComponent()
        let packageName = directory[directory.startIndex..<directory.range(of: ".git-", options: .backwards)!.lowerBound]
        let sourcePath = packagesURL.appendingPathComponent(directory).path
        let newPath = packagesURL.appendingPathComponent(String(packageName)).path
        do{
            //create the symlink
            if !FileManager.default.fileExists(atPath: newPath){
                let symlinkURL = URL(fileURLWithPath: newPath)
                let destinationURL = URL(fileURLWithPath: sourcePath)
                try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: destinationURL)
            }
        } catch let e {
            throw XcodeHelperError.clean(message: "Error creating symlink: \(e)")
        }
        
        return String(packageName)
    }
    func updateXcodeReferences(for versionedPackageName: String, at sourcePath: String, using symlinkName: String) throws {
        //find the xcodeproj
        let projectPath = try projectFilePath(for: sourcePath)
        //open the project
        let file = try String(contentsOfFile: projectPath)
        //replace versioned package name with symlink name
        let updatedFile = file.replacingOccurrences(of: versionedPackageName, with: symlinkName)
        //save the project
        try updatedFile.write(toFile: projectPath, atomically: false, encoding: String.Encoding.utf8)
    }
    
    public func projectFilePath(for sourcePath:String) throws -> String {
        var xcodeProjectPath: String?
        var pbProjectPath: String?
        do{
            xcodeProjectPath = try FileManager.default.contentsOfDirectory(atPath: sourcePath).filter({ (path) -> Bool in
                path.hasSuffix(".xcodeproj")
            }).first
            guard xcodeProjectPath != nil else {
                let message = "Failed to find xcodeproj at path: \(sourcePath)"
                logger.log(message, for: Command.updateMacOSPackages)
                throw XcodeHelperError.symlinkDependencies(message: message)
            }
        } catch let e {
            let message = "Error when trying to find xcodeproj at path: \(sourcePath).\nError: \(e)"
            logger.log(message, for: Command.updateMacOSPackages)
            throw XcodeHelperError.symlinkDependencies(message: message)
        }
        do{
            xcodeProjectPath = "\(sourcePath)/\(xcodeProjectPath!)"
            pbProjectPath = try FileManager.default.contentsOfDirectory(atPath: xcodeProjectPath!).filter({ (path) -> Bool in
                path.hasSuffix(".pbxproj")
            }).first
            guard pbProjectPath != nil else {
                let message = "Failed to find pbxproj at path: \(String(describing: xcodeProjectPath))"
                logger.log(message, for: Command.updateMacOSPackages)
                throw XcodeHelperError.symlinkDependencies(message: message)
            }
        } catch let e {
            let message = "Error when trying to find pbxproj at path: \(sourcePath).\nError: \(e)"
            logger.log(message, for: Command.updateMacOSPackages)
            throw XcodeHelperError.symlinkDependencies(message: message)
        }
        return "\(xcodeProjectPath!)/\(pbProjectPath!)"
    }
    
    //MARK: Create Archive
    @discardableResult
    public func createArchive(at archivePath:String, with filePaths:[String], flatList:Bool = true, shouldLog: Bool = true) throws -> ProcessResult {
        let command = Command.createArchive
        logger.log("Creating archive \(archivePath)", for: command)
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: archivePath).deletingLastPathComponent().path, withIntermediateDirectories: true, attributes: nil)
        let args = flatList ? filePaths.flatMap{ return ["-C", URL(fileURLWithPath:$0).deletingLastPathComponent().path, URL(fileURLWithPath:$0).lastPathComponent] } : filePaths
        let arguments = ["-cvzf", archivePath]+args
        let result = ProcessRunner.synchronousRun("/usr/bin/tar", arguments: arguments)
        if result.exitCode != 0, let error = result.error {
            let message = "Error creating archive: \(error)"
            logger.log(message, for: command)
            throw XcodeHelperError.createArchive(message: message)
        }
        logger.log("Archive created", for: command)
        return result
    }
    
    //MARK: Upload Archive
    public func uploadArchive(at archivePath:String, to s3Bucket:String, in region: String, key: String, secret: String, shouldLog: Bool = true) throws  {
        let command = Command.uploadArchive
        logger.log("Uploading archve: \(URL(fileURLWithPath: archivePath).lastPathComponent)", for: command)
        let result = try S3.with(key: key, and: secret).upload(file: URL.init(fileURLWithPath: archivePath), to: s3Bucket, in: region)
        if result.response.statusCode != 200 {
            var description = result.response.description
            if let data = result.data {
                if let text = String(data: data as Data, encoding: .utf8) {
                    description += "\n\(text)"
                }
            }
            logger.log(description, for: command)
            throw XcodeHelperError.uploadArchive(message: description)
        }
        logger.log("Archive uploaded", for: command)
    }
    
    public func uploadArchive(at archivePath:String, to s3Bucket:String, in region: String, using credentialsPath: String, shouldLog: Bool = true) throws  {
        let command = Command.uploadArchive
        logger.log("Uploading archve: \(URL(fileURLWithPath: archivePath).lastPathComponent)", for: command)
        let result = try S3.with(credentials: credentialsPath).upload(file: URL.init(fileURLWithPath: archivePath), to: s3Bucket, in: region)
        if result.response.statusCode != 200 {
            var description = result.response.description
            if let data = result.data {
                if let text = String(data: data as Data, encoding: .utf8) {
                    description += "\n\(text)"
                }
            }
            logger.log(description, for: command)
            throw XcodeHelperError.uploadArchive(message: description)
        }
        logger.log("Archive uploaded", for: command)
    }
    
    //MARK: Git Tag
    public func getGitTag(at sourcePath:String, shouldLog: Bool = true) throws -> String {
        let command = Command.gitTag
        let result = ProcessRunner.synchronousRun("/bin/bash", arguments: ["-c", "cd \(sourcePath) && /usr/bin/git tag"], printOutput: false)
        if result.exitCode != 0, let error = result.error {
            let message = "Error reading git tags: \(error)"
            logger.log(message, for: command)
            throw XcodeHelperError.gitTag(message: message)
        }
        
        //guard let tags = result.output!.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).components(separatedBy: "\n").last else {
        guard let tagStrings = result.output?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).components(separatedBy: "\n") else {
            let message = "Error parsing git tags: \(String(describing: result.output))"
            logger.log(message, for: command)
            throw XcodeHelperError.gitTag(message: message)
        }
        var tag: String = ""
        do {
            tag = try largestGitTag(tagStrings: tagStrings)
        }catch let e{
            logger.log(String(describing: e), for: command)
            throw e
        }
        
        logger.log(tag, for: command)
        return tag
    }
    
    
    public func gitTagTuple(_ tagString: String) -> (Int, Int, Int)? {
        let components = tagString.components(separatedBy: ".")
        guard components.count == 3, let major = Int(components[0]), let minor = Int(components[1]), let patch = Int(components[2]) else {
            return nil
        }
        return (major, minor, patch)
    }
    
    public func gitTagCompare(_ lhs:(Int, Int, Int), _ rhs: (Int, Int, Int)) -> Bool {
        if lhs.0 != rhs.0 {
            return lhs.0 < rhs.0
        }
        else if lhs.1 != rhs.1 {
            return lhs.1 < rhs.1
        }
        return lhs.2 < rhs.2
    }
    
    public func largestGitTag(tagStrings:[String]) throws -> String {
        let tags = tagStrings.flatMap(gitTagTuple)
        guard let tag = tags.sorted(by: {gitTagCompare($0, $1)}).last else {
            let message = "Git tag not found: \(tagStrings)"
            logger.log(message, for: Command.gitTag)
            throw XcodeHelperError.gitTag(message: message)
        }
        
        return "\(tag.0).\(tag.1).\(tag.2)"
    }
    
    @discardableResult
    public func incrementGitTag(component targetComponent: GitTagComponent = .patch, at sourcePath: String, shouldLog: Bool = true) throws -> String {
        let tag = try getGitTag(at: sourcePath)
        let oldVersionComponents = tag.components(separatedBy: ".")
        if oldVersionComponents.count != 3 {
            throw XcodeHelperError.gitTag(message: "Invalid git tag: \(tag). It should be in the format #.#.# major.minor.patch")
        }
        let newVersionComponents = oldVersionComponents.enumerated().map { (__val:(Int, String)) -> String in let (oldComponentValue,oldStringValue) = __val;
            if oldComponentValue == targetComponent.rawValue, let oldIntValue = Int(oldStringValue) {
                return String(describing: oldIntValue+1)
            }else{
                return oldComponentValue > targetComponent.rawValue ? "0" : oldStringValue
            }
        }
        let updatedTag = newVersionComponents.joined(separator: ".")
        do {
            try gitTag(updatedTag, repo: sourcePath)
            
            return try getGitTag(at: sourcePath)
        }catch let e{
            logger.log(String(describing: e), for: Command.gitTag)
            throw e
        }
    }
    
    public func gitTag(_ tag: String, repo sourcePath: String, shouldLog: Bool = true) throws {
        let result = ProcessRunner.synchronousRun("/bin/bash", arguments: ["-c", "cd \(sourcePath) && /usr/bin/git tag \(tag)"], printOutput: false)
        if result.exitCode != 0, let error = result.error {
            let message = "Error tagging git repo: \(error)"
            logger.log(message, for: Command.gitTag)
            throw XcodeHelperError.gitTag(message: message)
        }
    }
    
    public func pushGitTag(tag: String, at sourcePath:String, shouldLog: Bool = true) throws {
        let command = Command.gitTag
        logger.log("Pushing tag: \(tag)", for: command)
        let result = ProcessRunner.synchronousRun("/bin/bash", arguments: ["-c", "cd \(sourcePath) && /usr/bin/git push origin && /usr/bin/git push origin \(tag)"])
        if let error = result.error, result.exitCode != 0 || !error.contains("new tag") {
            let message = "Error pushing git tag: \(error)"
            logger.log(message, for: command)
            throw XcodeHelperError.gitTag(message: message)
        }
        logger.log("Pushed tag: \(tag)", for: command)
    }
    
    //MARK: Create XCArchive
    //returns a String for the path of the xcarchive
    public func createXcarchive(in dirPath: String, with binaryPath: String, from schemeName: String, shouldLog: Bool = true) throws -> String {
        let command = Command.createXcarchive
        logger.log("Creating XCAchrive \(URL(fileURLWithPath: binaryPath).lastPathComponent)", for: command)
        let name = URL(fileURLWithPath: binaryPath).lastPathComponent
        let directoryDate = xcarchiveDirectoryDate(from: dateFormatter)
        let archiveDate = xcarchiveDate(from: dateFormatter)
        let archiveName = "xchelper-\(name) \(archiveDate).xcarchive"
        let path = "\(dirPath)/\(directoryDate)/\(archiveName)"
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            try createXcarchivePlist(in: path, name: name, schemeName: schemeName)
            try createArchive(at: path.appending("/Products/\(name).tar"), with: [binaryPath])
            return path
        }catch let e{
            logger.log(String(describing: e), for: command)
            throw e
        }
    }
    
    private func xcarchiveDirectoryDate(from formatter: DateFormatter, from: Date = Date()) -> String {
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        return dateFormatter.string(from: from)
    }
    
    internal func xcarchiveDate(from formatter: DateFormatter, from: Date = Date()) -> String {
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "MM-dd-yyyy, h.mm.ss a"
        
        return dateFormatter.string(from: from)
    }
    
    internal func xcarchivePlistDateString(formatter: DateFormatter, from: Date = Date()) -> String {
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        
        return dateFormatter.string(from: from)
    }
    
    internal func createXcarchivePlist(in dirPath:String, name: String, schemeName:String) throws {
        let command = Command.createXcarchive
        logger.log("Creating Plist", for: command)
        let date = xcarchivePlistDateString(formatter: dateFormatter)
        let dictionary = ["ArchiveVersion": "2",
                          "CreationDate": date,
                          "Name": name,
                          "SchemeName": schemeName] as NSDictionary
        do{
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            try data.write(to: URL.init(fileURLWithPath: dirPath.appending("/Info.plist")) )
        }catch let e{
            let message = "Failed to create plist in: \(dirPath). Error: \(e)"
            logger.log(message, for: command)
            throw XcodeHelperError.xcarchivePlist(message: message)
        }
    }
    
}
