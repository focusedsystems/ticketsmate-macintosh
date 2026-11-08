import XCTest
@testable import TicketsMateCore

final class SignInRetryTests: XCTestCase {
    func testFailureBeforeSignInFinishesWaits() {
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: false, status: .signingIn), .waitForSignIn)
    }

    func testFailureAfterSignInFailedStillWaitsForALaterSignIn() {
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: false, status: .failed), .waitForSignIn)
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: true, status: .failed), .waitForSignIn)
    }

    func testSignInLandingMidRequestRetriesAtOnce() {
        // The sign-in change that would re-run the request already fired.
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: false, status: .signedIn), .retryNow)
    }

    func testFailureWhileSignedInIsReal() {
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: true, status: .signedIn), .showError)
    }

    func testUnconfiguredServiceNeverWaits() {
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: false, status: .notConfigured), .showError)
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: true, status: .notConfigured), .showError)
    }

    func testRetrySignsInFirstWhenSignInFailed() {
        XCTAssertEqual(SignInRetryTap.decide(status: .failed), .signInThenReload)
    }

    func testRetryWaitsWhileSignInIsRunning() {
        XCTAssertEqual(SignInRetryTap.decide(status: .signingIn), .waitForSignIn)
    }

    func testRetryReloadsWhenSignInIsNotTheProblem() {
        XCTAssertEqual(SignInRetryTap.decide(status: .signedIn), .reload)
        XCTAssertEqual(SignInRetryTap.decide(status: .notConfigured), .reload)
    }

}
