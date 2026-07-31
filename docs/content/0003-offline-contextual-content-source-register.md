# Batch 8C 场景化离线内容候选来源登记

- 状态：Candidate / 待真实人类内容、医疗与 App Review 分类复核
- 冻结来源：`https://github.com/AwantedRaccoon/MTF-Unmanual` @ `f39474389831840366c23fd274208319802bf2a5`
- 内容版本：`offline-contextual-content-candidate.1`
- 数量：48 张摘要、45 条外部书目、53 个场景 anchor
- 技术合同：[ADR 0020](../architecture/0020-batch-8c-offline-contextual-content.md)

## 认证边界

候选清单最初依据来源仓库本机的 ignored 编辑 sidecar 筛选；该 sidecar 不在冻结提交中，
因此它不能单独证明 Release 级 claim 复核。机器可读 lock 已把本次候选选择和外部书目
冻结在 App 仓库；生成器对每张实际打包摘要的来源路径执行
`git show <commit>:<path>` 并重算 SHA-256。此边界是 candidate-only，不能冒充
真实人类内容或医疗复核。

## 卡片与来源文件锁

| App ID | 类型 | 分类 | 到期 | 来源路径 | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| `card.identity-childhood-required-001` | `questionAnswer` | `mentalWellbeing` | `2027-06-04` | `cards/zh-CN/card_identity_childhood_required_001.md` | `8576985bc4f3d243670932b2788d131e9f20d6a7ff4855c1ddd2f3e2a0b6c690` |
| `card.dysphoria-required-002` | `questionAnswer` | `mentalWellbeing` | `2027-06-04` | `cards/zh-CN/card_dysphoria_required_002.md` | `bd068bdb74ede10197488a78aa371afa527d22eb66c85852eebc2acd9aa2df3a` |
| `card.medical-transition-required-003` | `questionAnswer` | `hrtAndCare` | `2026-12-04` | `cards/zh-CN/card_medical_transition_required_003.md` | `48a64f8aff302dd46f80ce279caac5a6553ae0d40064f2ce54fe56ab8152f210` |
| `card.hrt-what-changes-004` | `questionAnswer` | `hrtAndCare` | `2026-12-04` | `cards/zh-CN/card_hrt_what_changes_004.md` | `fd99ba132f85ac62755cd8ac62bb1b5c8ee63d3855a680aede3b887519a726eb` |
| `card.hrt-monitoring-005` | `questionAnswer` | `hrtAndCare` | `2026-09-04` | `cards/zh-CN/card_hrt_monitoring_005.md` | `91b66d1d2dbbf3d12ebe655f01cd85f779a45aaf60534dc67b57414362df9d2c` |
| `card.terms-feminising-006` | `questionAnswer` | `hrtAndCare` | `2027-06-04` | `cards/zh-CN/card_terms_feminising_006.md` | `a5c226713b905619281074581a918ba9cd6344f7b1d6bd79186ddefce3361be1` |
| `card.voice-not-only-pitch-007` | `questionAnswer` | `voiceAndPresentation` | `2026-12-04` | `cards/zh-CN/card_voice_not_only_pitch_007.md` | `92f88ab3f51319fc158271906fbb0daa0adaf7c06f08a813514111526e158a9e` |
| `card.family-names-pronouns-008` | `questionAnswer` | `privacyAndRelationships` | `2027-06-04` | `cards/zh-CN/card_family_names_pronouns_008.md` | `64f5ee2700c792ff51a3a560130ca3637bbe43d85e5416225918186b3c7a27c3` |
| `card.fertility-before-hrt-009` | `questionAnswer` | `hrtAndCare` | `2026-09-04` | `cards/zh-CN/card_fertility_before_hrt_009.md` | `81bca24c189a05e811947894c26f66b6a22c0edd45e4e486c0f972c4f7c90899` |
| `card.hrt-not-contraception-010` | `questionAnswer` | `hrtAndCare` | `2026-09-04` | `cards/zh-CN/card_hrt_not_contraception_010.md` | `a56296697fff3812f468b0011908255d28012189826a66017ce78c84ed178fa7` |
| `card.hrt-risks-011` | `questionAnswer` | `hrtAndCare` | `2026-09-04` | `cards/zh-CN/card_hrt_risks_011.md` | `ecee1db50099415c122617667c4e1800eb3d417fa401ee5cdd8b3e722d578b48` |
| `card.hair-removal-laser-electrolysis-012` | `questionAnswer` | `voiceAndPresentation` | `2026-12-04` | `cards/zh-CN/card_hair_removal_laser_electrolysis_012.md` | `c2aeaecc5b707ab972d57ccf85767d4b8a5afdf08803695fc88aaf7c92b50e80` |
| `card.surgery-hair-removal-013` | `questionAnswer` | `surgery` | `2026-12-04` | `cards/zh-CN/card_surgery_hair_removal_013.md` | `e9ac659390bcbb51477a1bdac3540350043c6cd81672b531627e311feb6a3126` |
| `card.tucking-not-required-014` | `questionAnswer` | `voiceAndPresentation` | `2026-12-04` | `cards/zh-CN/card_tucking_not_required_014.md` | `e7b1ecc70540fc43d0a1801526cd6027bc6f997695935df4af6b646deb86e43d` |
| `card.tucking-pain-015` | `questionAnswer` | `voiceAndPresentation` | `2026-09-04` | `cards/zh-CN/card_tucking_pain_015.md` | `d2a60d355ca5635579b9757e65f35ed009698194549f8fdd31e4d8d6be3853a9` |
| `card.preventive-organs-present-016` | `questionAnswer` | `preventiveCare` | `2027-06-04` | `cards/zh-CN/card_preventive_organs_present_016.md` | `38918b0d4e79893057c3fa2eb71414deb3f842b11b794a595fa93c3543004744` |
| `card.breast-screening-017` | `questionAnswer` | `preventiveCare` | `2026-12-04` | `cards/zh-CN/card_breast_screening_017.md` | `4cf5f16f0df1f75db866b83cda28e76a1ecdf5a75dfa9e34843ea889ebf801fa` |
| `card.prostate-screening-018` | `questionAnswer` | `preventiveCare` | `2026-09-04` | `cards/zh-CN/card_prostate_screening_018.md` | `036d7586b8aefdfe0cf1466fe21a32dd70dca1013908c51918f2b5aa86d4f13e` |
| `card.bone-health-019` | `questionAnswer` | `preventiveCare` | `2026-12-04` | `cards/zh-CN/card_bone_health_019.md` | `e1f69b783d66b8852fe01a81e1ccba3839b2c98aeb0694b34b82c71ef53f085f` |
| `card.sti-screening-anatomy-behavior-020` | `questionAnswer` | `sexualHealth` | `2026-12-04` | `cards/zh-CN/card_sti_screening_anatomy_behavior_020.md` | `72923b90a47cc35c92f9e70e081d01082b83b3f39933a7694db6b253ccc1349a` |
| `card.hiv-testing-prep-021` | `questionAnswer` | `sexualHealth` | `2026-12-04` | `cards/zh-CN/card_hiv_testing_prep_021.md` | `b3d0b7d1de664c861ab97436a6e02d67cea23d0ab00747ebfc65cb05d23e1741` |
| `card.prep-hrt-022` | `questionAnswer` | `sexualHealth` | `2026-09-04` | `cards/zh-CN/card_prep_hrt_022.md` | `f8585a0907681468abeadc70bf48f3c6f7761d694b83c81ba07f7cc4ba5d7abd` |
| `card.prep-not-all-sti-023` | `questionAnswer` | `sexualHealth` | `2026-09-04` | `cards/zh-CN/card_prep_not_all_sti_023.md` | `7ad5566c4e784f944817e7d788cae04cd2c62cb6daf06b248f0783f73486ddc9` |
| `card.hpv-vaccine-024` | `questionAnswer` | `sexualHealth` | `2026-12-04` | `cards/zh-CN/card_hpv_vaccine_024.md` | `90e70f7690c6c799bc99099656a15aef9695c883f20395b38ec5f1dbea685fa0` |
| `card.surgery-not-required-025` | `questionAnswer` | `surgery` | `2027-06-04` | `cards/zh-CN/card_surgery_not_required_025.md` | `55f9a2cfe45a3b974faca2aea4e91ca57c7d63ef181c2cb8d6912eecd7bdf2ce` |
| `card.surgery-options-026` | `questionAnswer` | `surgery` | `2026-12-04` | `cards/zh-CN/card_surgery_options_026.md` | `d3d2340d2fe1e598b4e06e1b7586342263508e85bba492d4ffd0a087ccba270c` |
| `card.vaginoplasty-vs-vulvoplasty-027` | `questionAnswer` | `surgery` | `2026-09-04` | `cards/zh-CN/card_vaginoplasty_vs_vulvoplasty_027.md` | `ff1c823ab58d60c9d6f2c7904c5c375824763b77801b52a4495ba753fab71979` |
| `card.vaginoplasty-dilation-028` | `questionAnswer` | `surgery` | `2026-09-04` | `cards/zh-CN/card_vaginoplasty_dilation_028.md` | `0e03088ddc001aa210c545107c192a8ccdc35fe242525db122183e0163ecc6bc` |
| `card.surgery-risks-consent-029` | `questionAnswer` | `surgery` | `2026-09-04` | `cards/zh-CN/card_surgery_risks_consent_029.md` | `765c8dd347e0580fc80828564747bead57b93194bb02ac24d205df1b90022764` |
| `card.therapy-not-identity-exam-030` | `questionAnswer` | `mentalWellbeing` | `2026-12-04` | `cards/zh-CN/card_therapy_not_identity_exam_030.md` | `59900b5ba818994b6c57c5b3bc8531ec9aff3c8930010909efc37a6e5d393c7a` |
| `card.mental-health-not-auto-block-031` | `questionAnswer` | `mentalWellbeing` | `2026-09-04` | `cards/zh-CN/card_mental_health_not_auto_block_031.md` | `3cf5473e281d6446a232b533f0a6e31dbf274917fd3d1526d53e0f0ee94d9059` |
| `card.finding-affirming-therapist-033` | `questionAnswer` | `mentalWellbeing` | `2026-12-04` | `cards/zh-CN/card_finding_affirming_therapist_033.md` | `d080616e437b74ac9d09002e39caeaec00fb2ecfaeecd0a28b1b68e34015cd50` |
| `card.support-networks-034` | `questionAnswer` | `mentalWellbeing` | `2026-12-04` | `cards/zh-CN/card_support_networks_034.md` | `6b473194e697c8a7c198db7c4f71a44889354a6b48636990d15c6a8ebfc75a45` |
| `card.coming-out-not-required-035` | `questionAnswer` | `privacyAndRelationships` | `2027-06-04` | `cards/zh-CN/card_coming_out_not_required_035.md` | `98e26bed0f758b547db00379c3bf9cdb2bc66a83f2fee9a4c1d16a3eb427d4a0` |
| `card.coming-out-safety-036` | `questionAnswer` | `privacyAndRelationships` | `2026-12-04` | `cards/zh-CN/card_coming_out_safety_036.md` | `271e9c63afbeaeb2ccc2d65f21b0d8530d59a63e1a03093acf114cf681569302` |
| `card.privacy-do-not-out-037` | `questionAnswer` | `privacyAndRelationships` | `2026-12-04` | `cards/zh-CN/card_privacy_do_not_out_037.md` | `f3389bb3c45a7dc4d3808c14600ad5a10d41b9dcdf8e0fd213c2f3ab3d5c3a7a` |
| `card.ally-no-invasive-questions-038` | `questionAnswer` | `sexualHealth` | `2026-12-04` | `cards/zh-CN/card_ally_no_invasive_questions_038.md` | `d31852707f5a88825558434bdcd127bd58576e33fcdc31f64502c7a7efca841f` |
| `card.gender-identity-orientation-039` | `questionAnswer` | `identityAndTerms` | `2027-06-04` | `cards/zh-CN/card_gender_identity_orientation_039.md` | `bb4e9271bc4589206cbc389f134cbba743c7a212132a9c2f36f7fdf19b7f97f0` |
| `card.mtf-transwoman-terms-040` | `questionAnswer` | `identityAndTerms` | `2027-06-04` | `cards/zh-CN/card_mtf_transwoman_terms_040.md` | `ee36495d2ba2a77b32e7d9cb8a7a68c2f23ab036af147d6b82a521bfdf14ce14` |
| `card.dysphoria-incongruence-terms-041` | `questionAnswer` | `mentalWellbeing` | `2027-06-04` | `cards/zh-CN/card_dysphoria_incongruence_terms_041.md` | `824ee3e749885325d21487aacaad1c96f980d61c94b3055522164d66f54a146d` |
| `card.terms-to-avoid-042` | `questionAnswer` | `privacyAndRelationships` | `2026-12-04` | `cards/zh-CN/card_terms_to_avoid_042.md` | `20eccb440c911c70aa7e4c11f7adfe59f4a084ed359a79bfc543a0ecf5629e48` |
| `card.no-rush-medical-transition-045` | `questionAnswer` | `identityAndTerms` | `2027-06-04` | `cards/zh-CN/card_no_rush_medical_transition_045.md` | `4cab55d3c5ec9562a08cf1348d0ecb740f8fa75664168abec1dd7f5b4c43763f` |
| `card.voice-resonance-not-just-pitch-050` | `questionAnswer` | `voiceAndPresentation` | `2026-12-04` | `cards/zh-CN/card_voice_resonance_not_just_pitch_050.md` | `934f102b6cf27ef5488ed91e81d937a8564eae668db855f6f1d96f9f8529a95b` |
| `card.gd-tucking-safe-057` | `questionAnswer` | `voiceAndPresentation` | `2026-09-04` | `cards/zh-CN/card_gd_tucking_safe_057.md` | `3faf6f2afc79dfd101f8d70405581cb3f3a7c9605cb9117ce218e5e65b233bb7` |
| `card.gd-when-seek-help-059` | `questionAnswer` | `mentalWellbeing` | `2026-09-05` | `cards/zh-CN/card_gd_when_seek_help_059.md` | `2f54609aae3042a76f1baa173a13ae0b529cb95a18597f7c79caa2b7277bc7d3` |
| `guide.regimen-field` | `recordingGuide` | `recordsAndVisits` | `2026-07-27` | `cards/zh-CN/card_estrogen_routes_054.md` | `b463e13f114527f50f03945a067699be42e214e78e80a9bc66dde0df434debb0` |
| `guide.lab-recording` | `recordingGuide` | `recordsAndVisits` | `2026-07-27` | `archive/quick/zh-CN/036-hrt-follow-up-records-and-labs.md` | `a785d71e2bc0b62134bc6c70163185f39192a427c766645668f7d30231a041ae` |
| `guide.visit-preparation` | `visitChecklist` | `recordsAndVisits` | `2026-07-27` | `archive/quick/zh-CN/034-hrt-first-visit-preparation.md` | `a4733ac71162738b87720cdecf8839d9fc060604d8e84183dc6a40e911a8d6b1` |

## 外部书目（仅链接）

| Source ID | 权利人/机构 | 标题 | 查阅 | 到期 | 固定 URL |
| --- | --- | --- | --- | --- | --- |
| `source.apa-gender-dysphoria-dsm5tr` | American Psychiatric Association | Gender Dysphoria | `2026-06-04` | `2027-06-04` | https://www.psychiatry.org/patients-families/gender-dysphoria |
| `source.apa-psychological-guidelines-tgnc-2015` | American Psychological Association | Guidelines for Psychological Practice with Transgender and Gender Nonconforming People | `2026-06-04` | `2026-09-04` | https://pubmed.ncbi.nlm.nih.gov/26653312/ |
| `source.asha-gender-affirming-voice` | American Speech-Language-Hearing Association | Gender Affirming Voice and Communication | `2026-06-04` | `2026-12-04` | https://www.asha.org/practice-portal/professional-issues/gender-affirming-voice-and-communication/ |
| `source.asrm-trans-fertility-access-2021` | American Society for Reproductive Medicine | Access to fertility services by transgender and nonbinary persons: an Ethics Committee opinion | `2026-06-04` | `2026-09-04` | https://www.asrm.org/practice-guidance/ethics-opinions/access-to-fertility-services-by-transgender-and-nonbinary-persons-an-ethics-committee-opinion-2021/ |
| `source.cdc-hpv-vaccine-recommendations-2024` | Centers for Disease Control and Prevention | HPV Vaccine Recommendations | `2026-06-04` | `2026-12-04` | https://www.cdc.gov/hpv/hcp/vaccination-considerations/index.html |
| `source.cdc-prep-clinical-guidance-2026` | Centers for Disease Control and Prevention | Clinical Guidance for PrEP | `2026-06-04` | `2026-09-04` | https://www.cdc.gov/hivnexus/hcp/prep/index.html |
| `source.cdc-prep-patient-2026` | Centers for Disease Control and Prevention | Preventing HIV with PrEP | `2026-06-04` | `2026-09-04` | https://www.cdc.gov/hiv/prevention/prep.html |
| `source.cdc-sti-screening-recommendations-2021` | Centers for Disease Control and Prevention | STI Screening Recommendations | `2026-06-04` | `2026-09-04` | https://www.cdc.gov/std/treatment-guidelines/screening-recommendations.htm |
| `source.cdc-sti-tgd-guidelines-2021` | Centers for Disease Control and Prevention | Transgender and Gender Diverse Persons | `2026-06-04` | `2026-12-04` | https://www.cdc.gov/std/treatment-guidelines/trans.htm |
| `source.endocrine-society-2017` | Endocrine Society | Endocrine Treatment of Gender-Dysphoric/Gender-Incongruent Persons: An Endocrine Society Clinical Practice Guideline | `2026-06-04` | `2026-09-04` | https://academic.oup.com/jcem/article/102/11/3869/4157558 |
| `source.endocrine-society-patient-treatments` | Endocrine Society | Transgender Health Treatments | `2026-06-04` | `2026-09-04` | https://www.endocrine.org/patient-engagement/endocrine-library/transgender-health-treatments |
| `source.glaad-trans-ally-tips` | GLAAD | Tips for Allies of Transgender People | `2026-06-04` | `2026-12-04` | https://glaad.org/transgender/allies/ |
| `source.glaad-trans-reference` | GLAAD | Transgender People: An Introduction | `2026-06-04` | `2026-12-04` | https://glaad.org/reference/transgender/ |
| `source.glaad-trans-terms-glossary` | GLAAD | Glossary of Terms: Transgender | `2026-06-04` | `2026-12-04` | https://glaad.org/reference/trans-terms |
| `source.johns-hopkins-fertility-preservation` | Johns Hopkins Medicine | Transgender Patients: Fertility Preservation Options | `2026-06-04` | `2026-09-04` | https://www.hopkinsmedicine.org/gynecology-obstetrics/specialty-areas/fertility-center/infertility-services/fertility-preservation-and-restoration-center/transgender-patients |
| `source.johns-hopkins-gaht` | Johns Hopkins Medicine | Gender-Affirming Hormone Therapy (GAHT) | `2026-06-04` | `2026-09-04` | https://www.hopkinsmedicine.org/health/treatment-tests-and-therapies/gender-affirming-hormone-therapy-gaht |
| `source.johns-hopkins-vaginoplasty-2025` | Johns Hopkins Medicine | Vaginoplasty for Gender Affirmation | `2026-06-04` | `2026-09-04` | https://www.hopkinsmedicine.org/health/expert-qa/vaginoplasty-for-gender-affirmation |
| `source.mayo-feminizing-hormone-therapy` | Mayo Clinic | Feminizing hormone therapy | `2026-06-04` | `2026-09-04` | https://www.mayoclinic.org/tests-procedures/feminizing-hormone-therapy/about/pac-20385096 |
| `source.mayo-feminizing-surgery-2024` | Mayo Clinic | Feminizing surgery | `2026-06-04` | `2026-09-04` | https://www.mayoclinic.org/tests-procedures/feminizing-surgery/about/pac-20385102 |
| `source.mtf-wiki` | Project Trans | MtF.wiki | `2026-06-04` | `2027-06-04` | https://github.com/project-trans/MtF-wiki |
| `source.nhc-cn-12356-psych-hotline` | 国家卫生健康委员会 | 国家卫生健康委关于应用“12356”全国统一心理援助热线电话号码的通知 | `2026-06-05` | `2026-09-05` | https://www.nhc.gov.cn/yzygj/c100068/202412/49a1a65386cd4be582d4702fd0926ee8.shtml |
| `source.pflag-national-glossary` | PFLAG | The PFLAG National Glossary: LGBTQ+ terminology | `2026-06-04` | `2027-06-04` | https://pflag.org/glossary/ |
| `source.pflag-trans-ally-guide` | PFLAG | Guide to Being An Ally to Trans and Nonbinary People | `2026-06-04` | `2026-12-04` | https://pflag.org/resource/trans-nonbinary-ally-guide/ |
| `source.planned-parenthood-coming-out-trans` | Planned Parenthood | Coming Out as Transgender and/or Nonbinary | `2026-06-04` | `2026-12-04` | https://www.plannedparenthood.org/learn/gender-identity/transgender/coming-out-trans |
| `source.rainbow-health-ontario-feminizing-ht` | Rainbow Health Ontario / Sherbourne Health | Primary Health Care for Trans Patients: Feminizing Hormone Therapy | `2026-06-04` | `2026-09-04` | https://www.rainbowhealthontario.ca/TransHealthGuide/gp-femht.html |
| `source.rainbow-preventive-transfem-checklist` | Rainbow Health Ontario / Sherbourne Health | Preventive Care Checklist for Transfeminine Patients | `2026-06-04` | `2026-12-04` | https://www.rainbowhealthontario.ca/wp-content/uploads/2020/04/Preventative-care-checklist-transfem-2019.pdf |
| `source.samhsa-crisis-help` | Substance Abuse and Mental Health Services Administration | Crisis Help: Suicide, Mental Health, Drug, and Alcohol Issues | `2026-06-04` | `2026-09-05` | https://www.samhsa.gov/find-support/in-crisis |
| `source.trans-care-bc-primary-care-toolkit` | Trans Care BC | Gender-affirming care for Trans, Two-Spirit and Gender Diverse Patients in BC: A Primary Care Toolkit | `2026-06-04` | `2026-12-04` | https://www.transcarebc.ca/sites/default/files/2024-03/Primary-Care-Toolkit.pdf |
| `source.transhub-feminising-hormones` | TransHub / ACON | Feminising | `2026-06-04` | `2026-09-04` | https://www.transhub.org.au/clinicians/feminising/ |
| `source.trevor-24-7-crisis-support` | The Trevor Project | Here for You 24/7: How to Reach Out to The Trevor Project | `2026-06-04` | `2026-12-04` | https://www.thetrevorproject.org/resources/guide/here-for-you-24-7-how-to-reach-out-to-the-trevor-project/ |
| `source.trevor-ally-guide` | The Trevor Project | Guide to Being an Ally to Transgender and Nonbinary Young People | `2026-06-04` | `2026-12-04` | https://www.thetrevorproject.org/resources/guide/a-guide-to-being-an-ally-to-transgender-and-nonbinary-youth/ |
| `source.trevor-allyship-in-action` | The Trevor Project | Allyship in Action | `2026-06-04` | `2027-06-04` | https://www.thetrevorproject.org/resources/guide/allyship-in-action/ |
| `source.trevor-coming-out-handbook` | The Trevor Project | The Coming Out Handbook | `2026-06-04` | `2026-12-04` | https://www.thetrevorproject.org/resources/guide/the-coming-out-handbook/ |
| `source.ucsf-bone-health-osteoporosis` | UCSF Gender Affirming Health Program | Bone health and osteoporosis | `2026-06-04` | `2026-12-04` | https://transcare.ucsf.edu/guidelines/bone-health-and-osteoporosis |
| `source.ucsf-breast-cancer-trans-women` | UCSF Gender Affirming Health Program | Screening for breast cancer in transgender women | `2026-06-04` | `2026-12-04` | https://transcare.ucsf.edu/guidelines/breast-cancer-women |
| `source.ucsf-feminizing-hormone-therapy` | UCSF Gender Affirming Health Program | Overview of feminizing hormone therapy | `2026-06-04` | `2026-12-04` | https://transcare.ucsf.edu/guidelines/feminizing-hormone-therapy |
| `source.ucsf-fertility-guideline` | UCSF Gender Affirming Health Program | Fertility options for transgender persons | `2026-06-04` | `2026-09-04` | https://transcare.ucsf.edu/guidelines/fertility |
| `source.ucsf-hair-removal` | UCSF Gender Affirming Health Program | Hair removal | `2026-06-04` | `2026-12-04` | https://transcare.ucsf.edu/guidelines/hair-removal |
| `source.ucsf-hiv-transgender` | UCSF Gender Affirming Health Program | Transgender health and HIV | `2026-06-04` | `2026-09-04` | https://transcare.ucsf.edu/guidelines/hiv |
| `source.ucsf-prostate-testicular-cancer` | UCSF Gender Affirming Health Program | Prostate and testicular cancer considerations in transgender women | `2026-06-04` | `2026-09-04` | https://transcare.ucsf.edu/guidelines/prostate-testicular-cancer |
| `source.ucsf-testicular-scrotal-pain` | UCSF Gender Affirming Health Program | Testicular and scrotal pain and related complaints | `2026-06-04` | `2026-09-04` | https://transcare.ucsf.edu/guidelines/testicular-pain |
| `source.ucsf-transition-roadmap` | UCSF Gender Affirming Health Program | Transition Roadmap | `2026-06-04` | `2026-12-04` | https://transcare.ucsf.edu/transition-roadmap |
| `source.ucsf-vaginoplasty-guideline` | UCSF Gender Affirming Health Program | Vaginoplasty procedures, complications and aftercare | `2026-06-04` | `2026-09-04` | https://transcare.ucsf.edu/guidelines/vaginoplasty |
| `source.who-icd11-gender-incongruence` | World Health Organization | Gender incongruence and transgender health in the ICD | `2026-06-04` | `2026-12-04` | https://www.who.int/standards/classifications/frequently-asked-questions/gender-incongruence-and-transgender-health-in-the-icd |
| `source.wpath-soc8` | World Professional Association for Transgender Health | Standards of Care for the Health of Transgender and Gender Diverse People, Version 8 | `2026-06-04` | `2026-09-04` | https://wpath.org/publications/soc8/ |

上述外部书目全部为 `linkOnly`，不打包第三方正文、图表、图片或受限数据，
也不因本项目的 CC BY-SA 4.0 署名而被再许可。

## 明确排除

- `card_breast_augmentation_timing_053`：至少一个 claim 缺少 next_review_due
- `card_crisis_support_032`：高时效热线及非固定 URL
- `card_estrogen_routes_054`：至少一个 claim 缺少 next_review_due
- `card_ffs_bone_not_hormones_052`：至少一个 claim 缺少 next_review_due
- `card_gd_euphoria_list_058`：至少一个 claim 缺少 next_review_due
- `card_gd_flare_first_step_056`：至少一个 claim 缺少 next_review_due
- `card_gender_euphoria_signal_044`：至少一个 claim 缺少 next_review_due
- `card_gender_euphoria_what_043`：至少一个 claim 缺少 next_review_due
- `card_hrt_does_not_change_voice_049`：至少一个 claim 缺少 next_review_due
- `card_legal_gender_marker_047`：至少一个 claim 缺少 next_review_due
- `card_legal_name_change_046`：至少一个 claim 缺少 next_review_due
- `card_name_vs_gender_marker_048`：至少一个 claim 缺少 next_review_due
- `card_self_medication_safety_055`：至少一个 claim 缺少 next_review_due
- `card_voice_health_strain_051`：至少一个 claim 缺少 next_review_due
