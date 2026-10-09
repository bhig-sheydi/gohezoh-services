"""Build docs/BDO_USER_MANUAL.pdf. Requires reportlab (pip install reportlab)."""

from html import escape
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    HRFlowable,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "BDO_USER_MANUAL.pdf"
FONT_DIR = Path("C:/Windows/Fonts")
if (FONT_DIR / "arial.ttf").exists():
    pdfmetrics.registerFont(TTFont("Manual", str(FONT_DIR / "arial.ttf")))
    pdfmetrics.registerFont(TTFont("ManualBold", str(FONT_DIR / "arialbd.ttf")))
else:
    FONT_DIR = Path("/usr/share/fonts/truetype/dejavu")
    pdfmetrics.registerFont(TTFont("Manual", str(FONT_DIR / "DejaVuSans.ttf")))
    pdfmetrics.registerFont(TTFont("ManualBold", str(FONT_DIR / "DejaVuSans-Bold.ttf")))
pdfmetrics.registerFontFamily("Manual", normal="Manual", bold="ManualBold")

GREEN = colors.HexColor("#173B34")
MID = colors.HexColor("#2C674E")
PALE = colors.HexColor("#EEF5EF")
INK = colors.HexColor("#233B31")
MUTED = colors.HexColor("#5D7165")
BORDER = colors.HexColor("#D9E6DA")

styles = getSampleStyleSheet()
styles.add(ParagraphStyle(name="CoverEyebrow", fontName="ManualBold", fontSize=10, leading=14, textColor=MID, spaceAfter=13))
styles.add(ParagraphStyle(name="CoverTitle", fontName="ManualBold", fontSize=29, leading=36, textColor=GREEN, spaceAfter=15))
styles.add(ParagraphStyle(name="CoverSub", fontName="Manual", fontSize=14, leading=22, textColor=MUTED, spaceAfter=14))
styles.add(ParagraphStyle(name="H1m", fontName="ManualBold", fontSize=18, leading=23, textColor=GREEN, spaceBefore=4, spaceAfter=12, keepWithNext=True))
styles.add(ParagraphStyle(name="H2m", fontName="ManualBold", fontSize=12, leading=17, textColor=MID, spaceBefore=14, spaceAfter=7, keepWithNext=True))
styles.add(ParagraphStyle(name="Bodym", fontName="Manual", fontSize=9.3, leading=14.1, textColor=INK, spaceAfter=8))
styles.add(ParagraphStyle(name="Smallm", fontName="Manual", fontSize=8.1, leading=11.5, textColor=INK, spaceAfter=5))
styles.add(ParagraphStyle(name="TableHeadm", fontName="ManualBold", fontSize=8.3, leading=11, textColor=colors.white))
styles.add(ParagraphStyle(name="TableCellm", fontName="Manual", fontSize=8.1, leading=11.5, textColor=INK))
styles.add(ParagraphStyle(name="TableLabelm", fontName="ManualBold", fontSize=8.1, leading=11.5, textColor=GREEN))
styles.add(ParagraphStyle(name="Stepm", fontName="Manual", fontSize=9.2, leading=14.1, textColor=INK, leftIndent=16, firstLineIndent=-16, spaceAfter=7))
styles.add(ParagraphStyle(name="Notem", fontName="Manual", fontSize=8.8, leading=13.3, textColor=GREEN))

story = []


def para(text, style="Bodym"):
    return Paragraph(text, styles[style])


def h1(text):
    story.append(para(escape(text), "H1m"))


def h2(text):
    story.append(para(escape(text), "H2m"))


def body(text):
    story.append(para(text))


def steps(items):
    for index, item in enumerate(items, 1):
        story.append(para(f"<b>{index}.</b> {item}", "Stepm"))


def note(text):
    box = Table([[para(text, "Notem")]], colWidths=[170 * mm])
    box.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), PALE),
        ("BOX", (0, 0), (-1, -1), 0.5, BORDER),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 9),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
    ]))
    story.extend([Spacer(1, 5 * mm), box, Spacer(1, 4 * mm)])


def fields(rows, first="Field", second="What to enter and why"):
    data = [[para(first, "TableHeadm"), para(second, "TableHeadm")]]
    data += [[para(escape(label), "TableLabelm"), para(detail, "TableCellm")] for label, detail in rows]
    table = Table(data, colWidths=[51 * mm, 119 * mm], repeatRows=1, hAlign="LEFT")
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), GREEN),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F8FBF8")]),
        ("GRID", (0, 0), (-1, -1), 0.35, BORDER),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
    ]))
    story.append(table)


def page():
    story.append(PageBreak())


story += [Spacer(1, 33 * mm), para("GOHEZOH  /  PEOPLE & PARTNERSHIPS", "CoverEyebrow"),
          para("Business Development<br/>Officer Manual", "CoverTitle"),
          para("Sign up, manage your pipeline, record work, and submit reports with the Gohezoh app.", "CoverSub"),
          HRFlowable(width="100%", thickness=2, color=MID), Spacer(1, 13 * mm)]
note("<b>Use the live app:</b> https://gohezoh-services.vercel.app/<br/><b>Audience:</b> Business Development Officers (BDOs). This manual follows the current app fields and approval rules.")
story += [Spacer(1, 22 * mm), para("A practical guide for your first day and your weekly routine.", "CoverSub"),
          Spacer(1, 5 * mm), para("Edition: 9 October 2026", "Smallm")]
page()

h1("1. Get your BDO account")
body("A BDO account is a staff account. Selecting Business Development during signup creates an <b>application</b>, not immediate access. A Super Admin must approve it after you confirm your email.")
steps([
    "Open <b>https://gohezoh-services.vercel.app/</b> and select <b>Create account</b> under the sign-in form.",
    "Enter the fields below. Under <b>Sign up as</b>, choose <b>Staff or logistics partner</b>; under <b>Requested category</b>, choose <b>Business Development</b>.",
    "Select <b>Create account</b>. Open the confirmation email and follow its link back to the Gohezoh site.",
    "Sign in with the same email and password. Your request remains pending until a Super Admin approves it. Refresh or sign in again after approval to load your workspace.",
])
fields([
    ("Your full name", "Your real name for your staff profile. Required."),
    ("Sign up as", "Choose <b>Staff or logistics partner</b>. The Customer option creates a customer account instead."),
    ("Requested category", "Choose <b>Business Development</b>. This tells the Super Admin which access you need; it does not grant access by itself."),
    ("Organization or partner name", "Optional on the form. Enter your employing organization or team if relevant. This does not create a logistics partner."),
    ("Email address", "Use an email you can open. Confirmation and password recovery arrive here. Required."),
    ("Password", "Choose a private password of at least eight characters. Required. Do not share it with colleagues."),
])
h2("If you already have a Gohezoh customer account")
body("Sign in to your existing account, select <b>Request staff access</b>, choose <b>Business Development</b> under Requested category, optionally enter an organization name, and select <b>Request access</b>. The page shows pending, approved, rejected, or revoked status and has a <b>Refresh status</b> button. You do not need to create a second account.")
note("If you forget your password, use <b>Forgot password?</b> on the sign-in screen. Enter the emailed eight-digit code in the app, then set a new password. Never send a password or recovery code to another person.")
page()

h1("2. Find your workspace and plan the day")
body("After approval, sign in and open <b>Business Development</b> in the top navigation. The <b>BDO workspace</b> contains dashboard counts, lead and partner forms, assigned pipelines, activity tracking, and weekly reports. Use <b>Refresh pipeline</b> when you need current data.")
fields([
    ("Assigned leads", "How many leads are assigned to you. Start with records needing action."),
    ("Follow-ups due", "Your immediate action queue. Open the related records and complete or reschedule each next step."),
    ("Meetings this week", "Meetings logged as activities this week."),
    ("Proposals", "Proposal-stage opportunities; review each for a clear next action."),
    ("Won opportunities", "Leads converted to customers. A lead becomes Won through conversion, not by selecting Won in the stage menu."),
    ("Won opportunity value", "Sum shown in naira (NGN) on the dashboard."),
    ("Assigned customers", "Customer relationships assigned to you after conversion or assignment."),
    ("Partner prospects", "Potential logistics partners in your development pipeline."),
    ("Activities this week", "Interactions logged this week. Record calls, meetings, and follow-ups promptly."),
])
h2("A reliable daily routine")
steps([
    "Open the dashboard and check <b>Follow-ups due</b> and the Assigned pipeline before contacting anyone.",
    "Call or email the contact, then <b>Record an interaction</b> against the correct lead, customer, or partner prospect.",
    "Update the lead's stage only when the evidence supports the move. Keep <b>Next action</b> and <b>Follow-up date</b> current.",
    "Review potential partners separately. Move a qualified partner to <b>Ready for approval</b> only after assessing their service and capacity.",
    "Refresh the pipeline before ending the day and check that every open priority record has an owner and next action.",
])
page()

h1("3. Add and qualify a business lead")
body("Use <b>Prospecting → Add a lead</b> for a business that may use Gohezoh services. A BDO's new lead is assigned to that BDO automatically. The <b>Assign to BDO</b> selector appears in management view, not in a normal BDO account. Fields marked required in the app must be completed.")
fields([
    ("Business name", "Registered or commonly used business name. Required; use a recognizable name to avoid duplicate records."),
    ("Contact person", "Person you will speak with. Required."),
    ("Phone", "Reachable contact number. Required; verify it before saving."),
    ("Email", "Contact email if known. Optional; use the contact's work address where possible."),
    ("Business type", "Short description such as retailer, manufacturer, or distributor. Optional."),
    ("City / State", "Where the business operates or needs service. Optional but useful for routing discussions."),
    ("Lead source", "How you found the lead, such as referral, event, online inquiry, or outreach. Optional."),
    ("Service interest", "The delivery, warehousing, fulfillment, or other Gohezoh service being discussed. Optional."),
    ("Opportunity value", "Estimated potential amount in NGN; enter a non-negative number when you have a credible estimate. This is not an approved price or invoice."),
    ("Follow-up date", "The next date you should act. Use it to keep the follow-up queue useful."),
    ("Next action", "Specific next step, e.g., 'Send service overview and call on Friday'."),
    ("Notes", "Relevant needs, decision makers, constraints, and agreed facts. Keep them concise and factual."),
])
note("Example: Enter 'Aba Retail Stores' as Business name, 'Chika Obi' as Contact person, 'Referral' as Lead source, 'Lagos deliveries' as Service interest, and a concrete follow-up date and next action. Select <b>Add lead</b> to save.")
page()

h1("4. Move a lead through the pipeline")
body("Open <b>Assigned pipeline</b>. Each card shows the lead number, business, contact details, service interest, potential value, follow-up date, and current stage. Use the <b>Stage</b> selector and <b>Edit follow-up details</b> on that card.")
fields([
    ("Lead", "New contact that needs discovery."),
    ("Qualified", "Fit and need are credible; record the evidence in Notes or an activity."),
    ("Opportunity", "There is a real business discussion with a defined service need and next step."),
    ("Proposal", "A proposal has been prepared or sent; record the proposal activity and response deadline."),
    ("Lost", "The opportunity will not proceed. Save the reason in Outcome/Notes before closing it."),
    ("Won", "Created automatically when an Opportunity or Proposal is converted to a customer."),
])
h2("Keep the record actionable")
body("Under <b>Edit follow-up details</b>, update <b>Next action</b>, <b>Follow-up date</b>, <b>Opportunity value</b>, <b>Outcome</b>, and <b>Notes</b>, then select <b>Save lead details</b>. Use Outcome to capture the result of a discussion; use Notes for supporting context. A vague next action such as 'Follow up' is less useful than 'Call procurement lead about trial delivery on 16 October'.")
h2("Convert a successful opportunity")
steps([
    "Confirm the lead is at <b>Opportunity</b> or <b>Proposal</b> and verify its business/contact details.",
    "Select <b>Convert to customer</b> on the lead card, then confirm the prompt.",
    "The app creates a customer record, marks the lead Won, and shows a customer number. Customer operations and pricing continue through their authorized workflows.",
])
note("BDOs cannot directly mark a lead Won, approve pricing, execute deliveries, or access finance settlements. Ask the appropriate team when those steps are needed.")
page()

h1("5. Develop potential logistics partners")
body("Use <b>Partner network development → Potential logistics partner</b> to record a company that might carry out deliveries. This creates a <b>prospect</b>, not an active operational partner.")
fields([
    ("Partner or company name", "Recognizable legal or trading name. Required."),
    ("Contact person / Phone", "Primary relationship contact and reachable number. Both required."),
    ("Email", "Business contact email, if available."),
    ("Service type", "The service they offer, e.g., courier or haulage."),
    ("City / State", "Their base or principal service location."),
    ("Coverage areas", "Comma-separated cities or routes, e.g., 'Lagos, Ibadan, Abeokuta'. The app stores each entry separately."),
    ("Capacity information", "Vehicle types, shipment capacity, operating hours, or other practical limits."),
    ("Follow-up date / Next action", "When and how you will validate or advance the relationship."),
])
h2("Development status")
body("In <b>Potential logistics partners</b>, use the Development status selector: <b>Identified</b> → <b>Contacted</b> → <b>Assessing</b> → <b>Ready for approval</b>. Select <b>Declined</b> if the prospect is unsuitable. Check coverage, capacity, contact reliability, and service fit before marking Ready for approval. Management or Admin must approve a ready prospect into the operational partner directory; approval initially creates a Pending operational partner.")
note("The BDO view does not approve partners. A partner prospect marked Ready for approval is a request for management review, not permission to assign jobs.")
page()

h1("6. Record every meaningful interaction")
body("Use <b>Activity tracking → Record an interaction</b> after a call, email, meeting, site visit, proposal, or follow-up. This creates a traceable activity against a selected record and updates the history shown below the forms.")
fields([
    ("Related lead, customer, or partner", "Choose the exact record the interaction concerns. Required; create the lead or prospect first if it is absent."),
    ("Activity type", "Choose Call, Email, Meeting, Site visit, Proposal, Follow-up, or Other. This drives reporting, so choose the closest match."),
    ("Subject", "Short, specific summary such as 'Discovery call about Lagos deliveries'. Required."),
    ("When it happened", "Actual interaction date and time. If left blank, the app uses the current time."),
    ("Details", "What was discussed, commitments, objections, and facts needed by the next colleague."),
    ("Next action", "The concrete next step agreed after the interaction."),
    ("Follow-up date", "When that next step is due. Use a date you can actually meet."),
])
h2("Good activity note example")
note("<b>Type:</b> Meeting<br/><b>Subject:</b> Trial delivery discussion with Aba Retail Stores<br/><b>Details:</b> Contact needs twice-weekly Lagos pickups; will share estimated parcel volume by Thursday.<br/><b>Next action:</b> Call Thursday to confirm volume and agree proposal scope.<br/><b>Follow-up date:</b> Thursday's date.")
body("Log the interaction soon after it happens. Link it to the correct record, use the actual time, and avoid entering speculative promises as confirmed facts. The activity history is a record of work done, while the lead or partner card holds its current state.")
page()

h1("7. Submit your weekly activity report")
body("Use <b>Weekly reporting → Submit activity report</b> for a completed period. The app calculates leads created, meetings, proposals, wins, and partner prospects from the records and activities already saved. You enter the period and your narrative summary.")
fields([
    ("Period start", "First date covered by the report. Required."),
    ("Period end", "Last date covered. Required; it cannot be before Period start or after today."),
    ("Summary", "At least ten characters; describe progress, wins, blockers, and planned follow-ups. Required."),
])
body("After selecting <b>Submit report</b>, look under <b>Recent reports</b> for the generated report number and date range. The report is a snapshot for that submission; check your activities and stage changes before submitting so the counts are meaningful.")
h2("Suggested Friday checklist")
steps([
    "Review Follow-ups due, every open Proposal, and every prospect Ready for approval.",
    "Confirm that this week's calls, meetings, proposals, and site visits were recorded against the right records.",
    "Update next actions and dates for work continuing into next week; close lost opportunities with a clear Outcome.",
    "Submit the report for the completed period with concrete wins, blockers, and next steps.",
])
h2("When something does not work")
fields([
    ("No BDO workspace", "Confirm your email, check that your Business Development request was approved, and sign in again. Use Request staff access → Refresh status to check the application."),
    ("A lead is missing", "The app shows records assigned to your account. Ask management to check the assignment. Do not create a duplicate merely to regain visibility."),
    ("Cannot mark Won", "Move the lead to Opportunity or Proposal, then use Convert to customer. Won is created by conversion."),
    ("Cannot approve partner", "Mark the prospect Ready for approval and ask Management or Admin to review it."),
    ("Report rejected", "Use a completed date range and a summary of at least ten characters; confirm that Period end is not in the future."),
], first="Issue", second="What to do")


def decorate(canvas, doc):
    canvas.saveState()
    width, height = A4
    if doc.page > 1:
        canvas.setFillColor(GREEN)
        canvas.rect(0, height - 16 * mm, width, 16 * mm, fill=1, stroke=0)
        canvas.setFont("ManualBold", 8.5)
        canvas.setFillColor(colors.white)
        canvas.drawString(20 * mm, height - 10.5 * mm, "GOHEZOH  /  BDO USER MANUAL")
    canvas.setStrokeColor(BORDER)
    canvas.line(20 * mm, 17 * mm, width - 20 * mm, 17 * mm)
    canvas.setFont("Manual", 7.5)
    canvas.setFillColor(MUTED)
    canvas.drawString(20 * mm, 11 * mm, "Gohezoh Integrated Services | 9 October 2026")
    canvas.drawRightString(width - 20 * mm, 11 * mm, f"Page {doc.page}")
    canvas.restoreState()


OUTPUT.parent.mkdir(parents=True, exist_ok=True)
doc = SimpleDocTemplate(str(OUTPUT), pagesize=A4, rightMargin=20 * mm, leftMargin=20 * mm,
                        topMargin=26 * mm, bottomMargin=22 * mm, title="Gohezoh BDO User Manual",
                        author="Gohezoh Integrated Services")
doc.build(story, onFirstPage=decorate, onLaterPages=decorate)
print(OUTPUT)
