//
//  XcodeHelperTests.swift
//  XcodeHelperKitTests
//
//  Created by Joel Saltzman on 7/30/16.
//
//

import XCTest
import SynchronousProcess
import DockerProcess
import S3Kit

//#if os(OSX) || os(iOS)
    import Darwin
//#elseif os(Linux)
//    import Glibc
//#endif

@testable
import XcodeHelperKit

enum LibraryTag: Int {
    case major = 1
    case minor = 0
    case patch = 3
}

let testPackageName = "Hello"
let testVersionedPackageName = "Hello-1.0.3"

class XcodeHelperTests: XCTestCase {
    
//    just create a sample repo that uses another repo so that we don't have to worry about swift version breakage
    let executableRepoURL = "https://github.com/saltzmanjoelh/HelloSwift" //we use a different repo for testing because this repo isn't meant for linux
    let libraryRepoURL = "https://github.com/saltzmanjoelh/Hello"
    var sourcePath : String?
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
        if sourcePath != nil {
            Process.run("/bin/rm", arguments: ["-Rf", sourcePath!])
        }
    }
    //returns the temp dir that we cloned into
    private func cloneToTempDirectory(repoURL:String) -> String? {
        //use /tmp instead of FileManager.default.temporaryDirectory because Docker for mac specifies /tmp by default and not /var...
//        guard let tempDir = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false).path.appending("/XcodeHelperKitTests/\(UUID())") else{
//            XCTFail("Failed to get user dir")
//            return nil
//        }
        let tempDir = "/tmp/\(UUID())"
        if !FileManager.default.fileExists(atPath: tempDir) {
            do {
                try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: false, attributes: nil)
            }catch _{
                
            }
        }
        let cloneResult = Process.run("/usr/bin/env", arguments: ["git", "clone", repoURL, tempDir], silenceOutput: false)
        XCTAssert(cloneResult.exitCode == 0, "Failed to clone repo: \(cloneResult.error)")
        XCTAssert(FileManager.default.fileExists(atPath: tempDir))
        print("done cloning temp dir: \(tempDir)")
        return tempDir
    }
    /*
    func testFetchPackages() {
        sourcePath = cloneToTempDirectory(repoURL: executableRepoURL)
        let helper = XcodeHelper()
        
        do {
            let fetchResult = try helper.fetchPackages(at: sourcePath!, forLinux: false, inDockerImage: nil)
            if let fetchError = fetchResult.error {
                XCTFail("Error: \(fetchError)")
            }
            XCTAssertNotNil(fetchResult.output)
            XCTAssertTrue(fetchResult.output!.contains("Resolved version"))
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testFetchPackagesInLinux() {
        sourcePath = cloneToTempDirectory(repoURL: executableRepoURL)
        let helper = XcodeHelper()
        
        do {
            let fetchResult = try helper.fetchPackages(at: sourcePath!, forLinux: true, inDockerImage: "saltzmanjoelh/swiftubuntu")
            if let fetchError = fetchResult.error {
                XCTFail("Error: \(fetchError)")
            }
            XCTAssertNotNil(fetchResult.output)
            XCTAssertTrue(fetchResult.output!.contains("Resolved version"), "Should have found \"Resolved version\" in output.")
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePath!.appending("/Packages"), isDirectory: &isDirectory), "Failed to find Packages dir")
            XCTAssertTrue(isDirectory.boolValue, "Packages symlink is not a directory")
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
 */
    func testProjectFilePath() {
        sourcePath = cloneToTempDirectory(repoURL: executableRepoURL)
        _ = Process.run("/bin/bash", arguments: ["-c", "cd \(sourcePath!) && /usr/bin/swift package generate-xcodeproj"])
        let helper = XcodeHelper()
        do {
            
            let path = try helper.projectFilePath(at: sourcePath!)
            XCTAssert(path.contains("/HelloSwift.xcodeproj/project.pbxproj"))
            
        } catch let e {
            XCTFail("Error: \(e)")
        }
        
    }
    func testPackageNames(){
        do{
            sourcePath = cloneToTempDirectory(repoURL: executableRepoURL)
            _ = Process.run("/bin/bash", arguments: ["-c", "cd \(sourcePath!) && /usr/bin/swift package generate-xcodeproj"])
            let helper = XcodeHelper()
            
            let packageNames = try helper.packageNames(from: sourcePath!)
            
            XCTAssertTrue(packageNames.count == 1)
            XCTAssertEqual(packageNames.first, testVersionedPackageName)
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testSymlinkDependencyPath(){
        do{
            sourcePath = cloneToTempDirectory(repoURL: executableRepoURL)
            _ = Process.run("/bin/bash", arguments: ["-c", "cd \(sourcePath!) && /usr/bin/swift package generate-xcodeproj"])
            let packages = [testPackageName]
            let helper = XcodeHelper()
            let packagesURL = URL(fileURLWithPath: sourcePath!).appendingPathComponent("Packages")
            let packageName = try helper.packageNames(from: sourcePath!).first
            let dependencyURL = packagesURL.appendingPathComponent(packageName!)
            
            let result = try helper.symlink(dependencyPath: dependencyURL.path)
            
            XCTAssertEqual(result, packages[0])
            let symlink = packagesURL.appendingPathComponent(result!).path
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlink)
            XCTAssertEqual(destination, dependencyURL.path)
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    
    func testUpdateXcodeReferences() {
        do {
            sourcePath = cloneToTempDirectory(repoURL: executableRepoURL)
            _ = Process.run("/bin/bash", arguments: ["-c", "cd \(sourcePath!) && /usr/bin/swift package generate-xcodeproj"])
            let helper = XcodeHelper()
            
            try helper.updateXcodeReferences(sourcePath: sourcePath!, versionedPackageName: testVersionedPackageName, symlinkName: testPackageName)
            
            let projectPath = try helper.projectFilePath(at: sourcePath!)
            let file = try String(contentsOfFile: projectPath)
            XCTAssertFalse(file.contains(testVersionedPackageName), "Xcode project should not contain any package versions")
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testShouldClean(){
        //build it in macOS so we know that it needs to be cleaned
        sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
        Process.run("/bin/bash", arguments: ["-c", "cd \(sourcePath!) && swift build"], silenceOutput: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: BuildConfiguration.debug.buildDirectory(inSourcePath: sourcePath!)), ".build directory not found after building in macOS")
        
        do{
            let ans = try XcodeHelper().shouldClean(sourcePath: sourcePath!, forConfiguration: .debug)
            
            XCTAssertTrue(ans, "shouldClean should have returned true")
            
        } catch let e {
            XCTFail("Error: \(e)")
        }
        
        
    }
    
    func testCleanLinuxBuilds() {
        //build first so that we have something to clean
        sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
        Process.run("/bin/bash", arguments: ["-c", "cd \(sourcePath!) && swift build"], silenceOutput: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: BuildConfiguration.debug.buildDirectory(inSourcePath: sourcePath!)), ".build directory not found after build in macOS")
        let helper = XcodeHelper()
        
        do {
            try helper.clean(sourcePath: sourcePath!)
            
            XCTAssertFalse(FileManager.default.fileExists(atPath: BuildConfiguration.debug.buildDirectory(inSourcePath: sourcePath!)), ".build directory should not found after cleaning")
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    
    func testBuildInLinux(){
        sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
        let helper = XcodeHelper()
        
        do {
            let result = try helper.build(source: sourcePath!, usingConfiguration: .debug, inDockerImage: "saltzmanjoelh/swiftubuntu", removeWhenDone: true)
            
            XCTAssertNil(result.error, result.error!)
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    
    func testArchiveFlatList(){
        let helper = XcodeHelper()
        sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
        let archivePath = "\(sourcePath!)/test.tar"
        
        do{
            try helper.createArchive(at:archivePath, with: ["\(sourcePath!)/Package.swift", "\(sourcePath!)/Sources/Hello.swift"], flatList: true)
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath), "Failed to create the archive")
            let subPath = sourcePath!.appending("/\(UUID())")//untar into subdir and make sure that there are no subsubdirs
            Process.run("/bin/bash", arguments: ["-c", "mkdir -p \(subPath) && /usr/bin/tar -xvf \(archivePath) -C \(subPath)"])
        
            let contents = try FileManager.default.contentsOfDirectory(atPath: subPath)
            XCTAssertEqual(contents.count, 2, "There should be exactly 2 files")
            XCTAssertFalse("\(contents)".contains("tmp"), "Flat list archiving shouldn't contain a directory structure")
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testStructuredArchive(){
        let helper = XcodeHelper()
        sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
        let archivePath = "\(sourcePath!)/test.tar"
        
        do{
            try helper.createArchive(at:archivePath, with: ["\(sourcePath!)/Package.swift", "\(sourcePath!)/Sources/Hello.swift"], flatList: false)
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath), "Failed to create the archive")
            let subPath = sourcePath!.appending("/\(UUID())")//untar into subdir and make sure that there are no subsubdirs
            Process.run("/bin/bash", arguments: ["-c", "mkdir -p \(subPath) && /usr/bin/tar -xvf \(archivePath) -C \(subPath)"])
        
            let contents = try FileManager.default.contentsOfDirectory(atPath: subPath)
            XCTAssertEqual(contents.count, 1, "There should be a root tmp directory")
            //make sure the subPath contains the structure from the archive
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: subPath.appending(sourcePath!)).count, 2, "There should be one Package.swift file and a Sources directory")
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }

    func testUploadArchive(){
        
        do{
            let credentialsPath = "/Users/joelsaltzman/Sites/XcodeHelper/XcodeHelperKit/s3Credentials.csv"
            let bucket = "saltzman.test"
            let region = "us-east-1"
            let helper = XcodeHelper()
            sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
            let archiveName = "test.zip"
            let archivePath = "\(sourcePath!)/\(archiveName)"
            try helper.createArchive(at:archivePath, with: ["\(sourcePath!)/Package.swift", "\(sourcePath!)/Sources/Hello.swift"], flatList: true)
            
            try helper.uploadArchive(at: archivePath, to: bucket, in: region, using: credentialsPath)
            
            
            
        } catch let e {
            XCTFail("Error: \(e)")
        }
        
    }
    
    func testGetGitTag() {
        do {
            let helper = XcodeHelper()
            sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
            
            let tag = try helper.getGitTag(sourcePath:sourcePath!)
            
            XCTAssertEqual(tag, "\(LibraryTag.major.rawValue).\(LibraryTag.minor.rawValue).\(LibraryTag.patch.rawValue)")
            
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testGitTagTuple() {
        let helper = XcodeHelper()
        
        let tag = helper.gitTagTuple("1.2.3")
        
        XCTAssertNotNil(tag)
        XCTAssert(tag!.0 == 1)
        XCTAssert(tag!.1 == 2)
        XCTAssert(tag!.2 == 3)
    }
    func testGitTagTuple_InvalidFormat() {
        let helper = XcodeHelper()
        
        let tag = helper.gitTagTuple("0.0")
        
        XCTAssertNil(tag)
    }
    func testLargestGitTag_Major() {
        do {
            let helper = XcodeHelper()
            
            let tag = try helper.largestGitTag(tagStrings: ["1000.1.1", "999.1.1", "1.1000.1", "1.1.1000"])
            
            XCTAssertEqual(tag, "1000.1.1")
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testLargestGitTag_Minor() {
        do {
            let helper = XcodeHelper()
            
            let tag = try helper.largestGitTag(tagStrings: ["1.1.1", "1.1000.1", "1.999.1", "1.1.1000"])
            
            XCTAssertEqual(tag, "1.1000.1")
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testLargestGitTag_Patch() {
        do {
            let helper = XcodeHelper()
            
            let tag = try helper.largestGitTag(tagStrings: ["1.1.1", "1.1000.1", "1.1000.1000"])
            
            XCTAssertEqual(tag, "1.1000.1000")
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    
    
    func testIncrementGitTagMajor() {
        do {
            let helper = XcodeHelper()
            sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
            let expectedValue = "\(LibraryTag.major.rawValue+1).0.0"
            
            let value = try helper.incrementGitTag(component: GitTagComponent.major, at: sourcePath!)
            
            XCTAssertEqual(value, expectedValue)
            let updatedTag = try helper.getGitTag(sourcePath:sourcePath!)
            XCTAssertEqual(updatedTag, expectedValue)
            
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testIncrementGitTagMinor() {
        do {
            let helper = XcodeHelper()
            sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
            let expectedValue = "\(LibraryTag.major.rawValue).\(LibraryTag.minor.rawValue+1).0"
            
            let value = try helper.incrementGitTag(component: GitTagComponent.minor, at: sourcePath!)
            
            XCTAssertEqual(value, expectedValue)
            let updatedTag = try helper.getGitTag(sourcePath:sourcePath!)
            XCTAssertEqual(updatedTag, expectedValue)
            
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testIncrementGitTagPatch() {
        do {
            let helper = XcodeHelper()
            sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
            let expectedValue = "\(LibraryTag.major.rawValue).\(LibraryTag.minor.rawValue).\(LibraryTag.patch.rawValue+1)"
            
            let value = try helper.incrementGitTag(component: GitTagComponent.patch, at: sourcePath!)
            
            XCTAssertEqual(value, value)
            let updatedTag = try helper.getGitTag(sourcePath:sourcePath!)
            XCTAssertEqual(updatedTag, expectedValue)
            
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    func testPushGitTagFailure() {
        do{
            let helper = XcodeHelper()
            sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
            
            try helper.pushGitTag(tag:"99.99.99", at: sourcePath!)
            
        } catch _ {
            return
        }
        XCTFail("Pushing an invalid tag should have thrown an error")
    }
    func testPushGitTag() {
        let helper = XcodeHelper()
        //get the current tag
        var tag: String?
        do {
            sourcePath = cloneToTempDirectory(repoURL: libraryRepoURL)
            tag = try helper.incrementGitTag(component: GitTagComponent.patch, at: sourcePath!)
        } catch let e {
            XCTFail("Error: \(e)")
        }
        defer { //cleanup
            let result = Process.run("/bin/bash", arguments: ["-c", "cd \(sourcePath!) && /usr/bin/git tag --delete \(tag!) && /usr/bin/git push origin :refs/tags/\(tag!)"])
            if result.exitCode != 0, let error = result.error {
                XCTFail("Error deleting git tag: \(error)")
            }
        }
        
        do{
            try helper.pushGitTag(tag:tag!, at: sourcePath!)
            
        } catch let e {
            XCTFail("Error: \(e)")
        }
    }
    
    func testCreateXcarchive() {
        
        do{
            let path = "/tmp"
            let appName = "TestApp"
            let schemeName = "TestAppScheme"
            let plist = "Info.plist"
            let binaryPath = "/tmp/\(appName)"
            FileManager.default.createFile(atPath: binaryPath, contents: "Hi".data(using: String.Encoding.utf8), attributes: nil)
            let helper = XcodeHelper()
            
            let archivePath = try helper.createXcarchive(in: path, with: binaryPath, from: schemeName)
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(archivePath)/\(plist)"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(archivePath)/Products/\(appName).tar"))
            try! FileManager.default.removeItem(atPath: URL(fileURLWithPath: archivePath).deletingLastPathComponent().path)
            
        } catch let e {
            XCTFail("Error: \(e)")
        }
        
    }
    
}
