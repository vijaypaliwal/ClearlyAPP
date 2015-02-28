/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "MainViewController.h"
@interface ViewController()

@end

@implementation ViewController

- (void)viewWillAppear:(BOOL)animated
{
    // Set the main view to utilize the entire application frame space of the device.
    // Change this to suit your view's UI footprint needs in your application.
    self.view.frame = [[UIScreen mainScreen] applicationFrame];
    
    [super viewWillAppear:animated];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    responseHandlers = [[NSMutableSet alloc] init];
    if(!incomingRequests){
        incomingRequests = [[NSMutableDictionary alloc] init];
    }
    requestsLock = [[NSLock alloc] init];
    socket = CFSocketCreate(kCFAllocatorDefault, AF_INET, SOCK_STREAM, IPPROTO_TCP, 0, NULL, NULL);
    if(!socket){
        //die no socket created
    }
    int reuse = true;
    int fileDescriptor = CFSocketGetNative(socket);
    if(setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(int)) != 0){
        // die no socket created
        NSLog(@"ERROR");
    }
    struct sockaddr_in address;

    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = __DARWIN_OSSwapInt32((u_int32_t)0x00000000);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    int port_num = [[defaults stringForKey:@"port_num"] intValue]?[[defaults stringForKey:@"port_num"] intValue]:8004;
    address.sin_port = __DARWIN_OSSwapInt16(port_num);
    CFDataRef addressData =
    CFDataCreate(NULL, (const UInt8 *)&address, sizeof(address));
    [(id)addressData autorelease];

    if (CFSocketSetAddress(socket, addressData) != kCFSocketSuccess) {
        //error
        NSLog(@"ERROR");
    }

    listeningHandle = [[NSFileHandle alloc]
                                                initWithFileDescriptor:fileDescriptor
                                                closeOnDealloc:YES];

    [[NSNotificationCenter defaultCenter]
            addObserver:self
            selector:@selector(receiveIncomingConnectionNotification:)
            name:NSFileHandleConnectionAcceptedNotification
            object:nil];
    [listeningHandle acceptConnectionInBackgroundAndNotify];
	// Do any additional setup after loading the view, typically from a nib.
}

- (void)receiveIncomingConnectionNotification:(NSNotification *)notification {
    NSDictionary *userInfo = [notification userInfo];
    NSFileHandle *incomingFileHandle =
    [userInfo objectForKey:NSFileHandleNotificationFileHandleItem];

    if(incomingFileHandle) {
        [requestsLock lock];
        CFHTTPMessageRef *ref = [(id)CFHTTPMessageCreateEmpty(kCFAllocatorDefault, TRUE) autorelease];
        [incomingRequests setObject:(id)ref forKey:[NSString stringWithFormat:@"%i", [incomingFileHandle fileDescriptor]]];
        [requestsLock unlock];

        [[NSNotificationCenter defaultCenter]
            addObserver:self
            selector:@selector(receiveIncomingDataNotification:)
            name:NSFileHandleDataAvailableNotification
            object:incomingFileHandle];

        [incomingFileHandle waitForDataInBackgroundAndNotify];
    }

  [listeningHandle acceptConnectionInBackgroundAndNotify];
}
- (void)stopReceivingForFileHandle:(NSFileHandle *)incomingFileHandle
                             close:(BOOL)closeFileHandle {
    if (closeFileHandle) {
        [incomingFileHandle closeFile];
    }

    [[NSNotificationCenter defaultCenter]
            removeObserver:self
            name:NSFileHandleDataAvailableNotification
            object:incomingFileHandle];
    [requestsLock lock];
    [incomingRequests removeObjectForKey:[NSString stringWithFormat:@"%i", [incomingFileHandle fileDescriptor]]];
    [requestsLock unlock];
}
- (void)receiveIncomingDataNotification:(NSNotification *)notification {
    [requestsLock lock];
    NSFileHandle *incomingFileHandle = [notification object];
    NSData *data = [incomingFileHandle availableData];

    if ([data length] == 0) {
        [self stopReceivingForFileHandle:incomingFileHandle close:NO];
        return;
    }

    CFHTTPMessageRef incomingRequest = (CFHTTPMessageRef) [incomingRequests valueForKey:[NSString stringWithFormat:@"%i", [incomingFileHandle fileDescriptor]]];
    [requestsLock unlock];
    if (!incomingRequest) {
        [self stopReceivingForFileHandle:incomingFileHandle close:YES];
        return;
    }
    if (!CFHTTPMessageAppendBytes(
                                  incomingRequest,
                                  [data bytes],
                                  [data length]))
    {
        [self stopReceivingForFileHandle:incomingFileHandle close:YES];
        return;
    }

    if(CFHTTPMessageIsHeaderComplete(incomingRequest)) {
        NSURL *url = [(NSURL *)CFHTTPMessageCopyRequestURL(incomingRequest) autorelease];
        if([[url absoluteString] rangeOfString:@"/"].location != 0){
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1);
            CFHTTPMessageSetHeaderFieldValue(
                                             response, (CFStringRef)@"Content-Type", (CFStringRef)@"text/plain");
            CFHTTPMessageSetHeaderFieldValue(
                                             response, (CFStringRef)@"Connection", (CFStringRef)@"close");
            CFHTTPMessageSetHeaderFieldValue(
                                             response,
                                             (CFStringRef)@"Content-Length",
                                             (CFStringRef)@"0");
            CFDataRef headerData = CFHTTPMessageCopySerializedMessage(response);
            @try {
                CDVCommandQueue *commandQueue = [self commandQueue];
                [[self commandQueue] fetchCommandsFromJs];
                [incomingFileHandle writeData:(NSData *)headerData];
                [incomingFileHandle writeData:[[[NSData alloc] init] autorelease]];
            }
            @catch (NSException *exception) {
                // Ignore the exception, it normally just means the client
                // closed the connection from the other end.
            }
            @finally {
                CFRelease(headerData);
                [self closeHandler:incomingFileHandle];
            }
            return;
        }else{
            NSData *fileData;
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:[url path]];
            if (exists) {
                fileData = [NSData dataWithContentsOfFile:[url path]];
            }else{
                fileData = [[[NSData alloc] init] autorelease];
            }
            CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1);
            CFHTTPMessageSetHeaderFieldValue(
                                         response, (CFStringRef)@"Content-Type", (CFStringRef)@"text/plain");
            CFHTTPMessageSetHeaderFieldValue(
                                         response, (CFStringRef)@"Connection", (CFStringRef)@"close");
            CFHTTPMessageSetHeaderFieldValue(
                                         response,
                                         (CFStringRef)@"Content-Length",
                                         (CFStringRef)[NSString stringWithFormat:@"%i", [fileData length]]);
            CFDataRef headerData = CFHTTPMessageCopySerializedMessage(response);
            @try {
                [incomingFileHandle writeData:(NSData *)headerData];
                [incomingFileHandle writeData:fileData];
            }
            @catch (NSException *exception) {
                // Ignore the exception, it normally just means the client
                // closed the connection from the other end.
            }
            @finally {
                CFRelease(headerData);
                [self closeHandler:incomingFileHandle];
            }
        }
        return;
    }

    [incomingFileHandle waitForDataInBackgroundAndNotify];
}
- (void)closeHandler: (NSFileHandle *)incomingFileHandle {
    if (incomingFileHandle) {
        [[NSNotificationCenter defaultCenter]
            removeObserver:self
            name:NSFileHandleDataAvailableNotification
            object:incomingFileHandle];
        [requestsLock lock];
        if([incomingRequests valueForKey:[NSString stringWithFormat:@"%i", [incomingFileHandle fileDescriptor]]]){
            [incomingRequests removeObjectForKey:[NSString stringWithFormat:@"%i", [incomingFileHandle fileDescriptor]]];
        }
        [requestsLock unlock];
        [incomingFileHandle closeFile];
        incomingFileHandle = nil;
    }
}
- (void)viewDidUnload
{
    [requestsLock lock];
    for(NSFileHandle *req in incomingRequests){
        [self stopReceivingForFileHandle:req close:YES];
    }
    [requestsLock unlock];
    if (socket){
        CFSocketInvalidate(socket);
        CFRelease(socket);
        socket = nil;
    }
    [requestsLock release];
    requestsLock = nil;
    [incomingRequests release];
    incomingRequests = nil;
    [super viewDidUnload];
    // Release any retained subviews of the main view.
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    return [super shouldAutorotateToInterfaceOrientation:interfaceOrientation];
}

@end