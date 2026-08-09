# Message Composition with MML (MIME Meta Language)

Himalaya uses MML for composing emails. MML is a simple XML-based syntax that compiles to MIME messages.

## Basic Message Structure

Headers, blank line, then body:

```
From: sender@example.com
To: recipient@example.com
Subject: Hello World

This is the message body.
```

## Headers

- `From`, `To`, `Cc`, `Bcc`, `Subject`, `Reply-To`, `In-Reply-To`

Address formats:

```
To: user@example.com
To: John Doe <john@example.com>
To: user1@example.com, user2@example.com
```

## Plain Text

```
From: alice@localhost
To: bob@localhost
Subject: Plain Text Example

Hello, this is a plain text email.
```

## Multipart alternative (text + HTML)

```
From: alice@localhost
To: bob@localhost
Subject: Multipart Example

<#multipart type=alternative>
This is the plain text version.
<#part type=text/html>
<html><body><h1>This is the HTML version</h1></body></html>
<#/multipart>
```

## Attachments

```
From: alice@localhost
To: bob@localhost
Subject: With Attachment

Here is the document.

<#part filename=/path/to/document.pdf><#/part>
```

Custom display name:

```
<#part filename=/path/to/file.pdf name=report.pdf><#/part>
```

## Inline images

```
From: alice@localhost
To: bob@localhost
Subject: Inline Image

<#multipart type=related>
<#part type=text/html>
<html><body><img src="cid:image1"></body></html>
<#part disposition=inline id=image1 filename=/path/to/image.png><#/part>
<#/multipart>
```

## CLI compose flows

```bash
himalaya message write
himalaya message reply 42
himalaya message reply 42 --all
himalaya message forward 42
cat message.txt | himalaya template send
```

Confirm with the user before sending. Prefer `auth.cmd` / keyring over embedding secrets in the message file.
