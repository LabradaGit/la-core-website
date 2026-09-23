document.querySelector('.menu')?.addEventListener('click',()=>document.querySelector('.top').classList.toggle('open'));
const form=document.querySelector('#project-form');
if(form){const params=new URLSearchParams(location.search);if(params.get('type')==='lead')document.querySelector('#project-type').value='Lead Inspection';form.addEventListener('submit',e=>{e.preventDefault();const d=new FormData(form);const subject=encodeURIComponent('Project Request - '+d.get('type'));const body=encodeURIComponent(`Name: ${d.get('name')}
Phone: ${d.get('phone')}
Email: ${d.get('email')}
Project type: ${d.get('type')}

Project details:
${d.get('details')}`);location.href=`mailto:lacoredgroupllc@gmail.com?subject=${subject}&body=${body}`;});}